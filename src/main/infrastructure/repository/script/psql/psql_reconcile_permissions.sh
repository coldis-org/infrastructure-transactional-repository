#!/bin/sh
#
# Wrapper for reconcile_permissions() (v0 — USER lifecycle).
# Replaces psql_users_add.sh + psql_users_remove.sh. Reads the existing
# PSQL_* env vars, resolves LDAP membership, calls the SQL function.
#
# Performance: 1 ldapsearch (OR filter across all groups), 1 psql -c.
# Invoked from psql_configure.sh at boot and from cron hourly.

set -eu

DEBUG=${DEBUG:=false}
ENV_FILE="${RECONCILE_ENV_FILE:-/local/application.env}"
LOG_FILE="/tmp/reconcile_permissions.log"
RECONCILE_SOURCE="${RECONCILE_SOURCE:-cron}"   # boot | cron | manual
LDAP_NETTIMEOUT="${LDAP_NETTIMEOUT:-10}"

# Boot/manual: surface logs to stdout for the operator. Cron stays quiet.
if [ "$RECONCILE_SOURCE" = "boot" ] || [ "$RECONCILE_SOURCE" = "manual" ]; then
    DEBUG=true
fi

printf '[psql_reconcile_permissions] start (source=%s, debug=%s, ldap_nettimeout=%ss)\n' \
    "$RECONCILE_SOURCE" "$DEBUG" "$LDAP_NETTIMEOUT" >&2

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/reconcile_permissions.log"

# Legacy fallback: build LDAP_HOST from LDAP_URI:LDAP_PORT if unset.
# Strip ldap://, ldaps:// prefix defensively (LDAP_URI is sometimes set to a
# full URL — without stripping we'd end up with "ldap://ldap://host:389").
if [ -z "${LDAP_HOST:-}" ]; then
    LDAP_HOST="${LDAP_URI:-}:${LDAP_PORT:-}"
    LDAP_HOST="${LDAP_HOST#ldap://}"
    LDAP_HOST="${LDAP_HOST#ldaps://}"
    [ "$LDAP_HOST" = ":" ] && LDAP_HOST=""
fi
# Same scheme strip if LDAP_HOST itself was set with a scheme prefix.
LDAP_HOST="${LDAP_HOST#ldap://}"
LDAP_HOST="${LDAP_HOST#ldaps://}"

: "${POSTGRES_ADMIN_USER:=postgres}"
: "${POSTGRES_ADMIN_PASSWORD:=postgres}"

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
    printf '[%s] %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"
    ${DEBUG} && printf '[%s] %s\n' "$(timestamp)" "$*"
    return 0
}

# err: writes to LOG_FILE and stderr, so it surfaces even when the caller
# uses `|| true`.
err() {
    printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"
    printf '[psql_reconcile_permissions] ERROR: %s\n' "$*" >&2
    return 0
}

mask() {
    s="${1:-}"; len=${#s}
    if [ "$len" -le 4 ]; then printf '****'
    else printf '%s****%s' "$(printf '%s' "$s" | cut -c1-2)" "$(printf '%s' "$s" | cut -c$((len-1))-)"; fi
}

# Fail-fast on missing env vars, otherwise `set -u` would abort at a less
# obvious point and the `|| true` in the caller would swallow it.
MISSING=""
for v in LDAP_HOST LDAP_USER LDAP_PASSWORD LDAP_GROUPS POSTGRES_DEFAULT_DATABASE; do
    eval "val=\${$v:-}"
    [ -z "$val" ] && MISSING="$MISSING $v"
done
if [ -n "$MISSING" ]; then
    err "missing env vars:$MISSING"
    err "set them via ENV_FILE=$ENV_FILE or docker -e ... Aborting."
    exit 3
fi

log "LDAP config: host=${LDAP_HOST} base=${LDAP_GROUPS} bind_dn=${LDAP_USER} password=$(mask "${LDAP_PASSWORD}")"

# Isolated bind test: separates connectivity/auth issues from filter issues.
log "Testing LDAP bind..."
LDAP_BIND_TEST=$(ldapsearch -LLL -o "nettimeout=${LDAP_NETTIMEOUT}" \
    -w "${LDAP_PASSWORD}" -D "${LDAP_USER}" \
    -H "ldap://${LDAP_HOST}" -b "${LDAP_GROUPS}" -s base \
    "(objectClass=*)" dn 2>&1) || {
    rc=$?
    err "LDAP bind failed (exit $rc) at ldap://${LDAP_HOST}"
    printf '%s\n' "$LDAP_BIND_TEST" | sed 's/^/  | /' >> "$LOG_FILE"
    err "Check: host reachable (telnet $LDAP_HOST 389), bind DN, base DN. Log: $LOG_FILE"
    exit $rc
}
log "Bind OK."

# Union of LDAP groups referenced across PSQL_READ_SCHEMA_*, PSQL_WRITE_SCHEMA_*,
# PSQL_ALTER_GROUP_* env vars. Comma-separated values are split.
GROUPS=$(env | awk -F= '
    /^PSQL_READ_SCHEMA_|^PSQL_WRITE_SCHEMA_|^PSQL_ALTER_GROUP_/ {
        n = split($2, parts, ",")
        for (i = 1; i <= n; i++) {
            g = parts[i]
            gsub(/^[ \t]+|[ \t]+$/, "", g)
            if (g != "") print g
        }
    }
' | sort -u)

if [ -z "$GROUPS" ]; then
    err "no LDAP groups referenced in PSQL_* env vars; aborting (likely misconfig)"
    exit 2
fi

GROUP_COUNT=$(printf '%s\n' "$GROUPS" | wc -l)

# LDAP filter injection guard: validate group names against a strict character
# set before interpolating into `(cn=...)`. RFC 4515 requires escaping of
# `( ) * \ NUL`; we reject instead of escape since group names should never
# contain those.
INVALID_GROUPS=$(printf '%s\n' "$GROUPS" | grep -Ev '^[a-zA-Z0-9._-]+$' || true)
if [ -n "$INVALID_GROUPS" ]; then
    err "invalid LDAP group name(s) — only [a-zA-Z0-9._-] allowed:"
    printf '%s\n' "$INVALID_GROUPS" | sed 's/^/  - /' >&2
    exit 4
fi

log "Resolving ${GROUP_COUNT} LDAP group(s) (with intended schema/table context):"

# Per-group context: which env var referenced this group and for what
# (READ/WRITE on which schema/table, or GROUP-MEMBER-OF a derived group).
# Informational only — v0 of reconcile_permissions doesn't materialize GRANTs
# yet, but the context is useful for debug and primes the next iteration.
env | awk -F= '
    function parse_schema_table(key,    idx, schema, table) {
        idx = index(key, "_TABLE_")
        if (idx > 0) {
            schema = substr(key, 1, idx - 1)
            table  = substr(key, idx + length("_TABLE_"))
            return tolower(schema) "." tolower(table)
        }
        return tolower(key)
    }
    function emit_groups(line, action, target,    n, gs, i, g) {
        n = split(line, gs, ",")
        for (i = 1; i <= n; i++) {
            g = gs[i]; gsub(/^[ \t]+|[ \t]+$/, "", g)
            if (g != "") printf "  - %s\t%s %s\n", g, action, target
        }
    }
    /^PSQL_READ_SCHEMA_/  { key = $1; sub(/^PSQL_READ_SCHEMA_/,  "", key); emit_groups($2, "READ",  parse_schema_table(key)) }
    /^PSQL_WRITE_SCHEMA_/ { key = $1; sub(/^PSQL_WRITE_SCHEMA_/, "", key); emit_groups($2, "WRITE", parse_schema_table(key)) }
    /^PSQL_ALTER_GROUP_/  { key = $1; sub(/^PSQL_ALTER_GROUP_/,  "", key); emit_groups($2, "GROUP-MEMBER-OF", tolower(key)) }
' | sort | tee -a "$LOG_FILE"

LDAP_FILTER=$(printf '%s\n' "$GROUPS" | awk '
    BEGIN { f = "(|" }
    { f = f "(cn=" $0 ")" }
    END { print f ")" }
')
log "LDAP filter: ${LDAP_FILTER}"

LDAP_OUTPUT=$(ldapsearch -LLL -o "nettimeout=${LDAP_NETTIMEOUT}" \
    -w "$LDAP_PASSWORD" -D "$LDAP_USER" \
    -H "ldap://$LDAP_HOST" -b "$LDAP_GROUPS" \
    "$LDAP_FILTER" memberUid 2>>"$LOG_FILE") || {
    rc=$?
    err "ldapsearch failed (exit $rc). Filter: $LDAP_FILTER. Log: $LOG_FILE"
    exit $rc
}

USERS=$(printf '%s\n' "$LDAP_OUTPUT" | awk '/^memberUid: / { print $2 }' | sort -u)
if [ -z "$USERS" ]; then
    USER_COUNT=0
    log "no users resolved — filter likely didn't match any group; check group names"
else
    USER_COUNT=$(printf '%s\n' "$USERS" | wc -l)
fi
log "${USER_COUNT} unique user(s) resolved"

# PG array literal: each user wrapped in single quotes (string literal).
# Double quotes would be identifier quoting and cause "column does not exist".
if [ -z "$USERS" ]; then
    PG_ARRAY=""
else
    PG_ARRAY=$(printf '%s\n' "$USERS" \
        | sed "s/'/''/g; s/.*/'&'/" \
        | paste -sd ',' -)
fi

# Owner fallback for REASSIGN OWNED on DROP USER. Optional: if
# POSTGRES_DEFAULT_USER is unset (cluster ran without a default app user),
# pass NULL and let the SQL function fall back to CURRENT_USER (admin).
if [ -n "${POSTGRES_DEFAULT_USER:-}" ]; then
    OWNER_ARG="'${POSTGRES_DEFAULT_USER}'"
else
    OWNER_ARG="NULL"
fi

log "Calling reconcile_permissions (source=${RECONCILE_SOURCE}, target=${USER_COUNT}, owner_fallback=${POSTGRES_DEFAULT_USER:-<CURRENT_USER>})"

PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql \
    -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DEFAULT_DATABASE" \
    -t -A -F '|' \
    -c "SET statement_timeout = '60s';
        SELECT action || '|' || username
          FROM reconcile_permissions(
              ARRAY[${PG_ARRAY}]::TEXT[],
              '${RECONCILE_SOURCE}',
              ${OWNER_ARG}
          );" \
    >> "$LOG_FILE" 2>&1
rc=$?

if [ $rc -eq 0 ]; then
    log "OK"
    exit 0
else
    err "psql exit $rc"
    exit $rc
fi
