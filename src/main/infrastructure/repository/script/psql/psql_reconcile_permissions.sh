#!/bin/sh
#
# Reconciles LDAP-managed database users with LDAP (see sql/reconcile_permissions.sql).
# Replaces psql_users_add, psql_users_remove and psql_users_alter_group. Run at boot by
# psql_configure.sh and hourly by cron.
#
# Configuration, from the environment (and /local/application.env, re-read every run):
#   PSQL_READ_SCHEMA_<SCHEMA>=g1,g2               read on a whole schema
#   PSQL_READ_SCHEMA_<SCHEMA>_TABLE_<TABLE>=g1     read on one table
#   PSQL_WRITE_SCHEMA_<SCHEMA>=g1                  write on a whole schema
#   PSQL_ALTER_GROUP_<ROLE>=g1                     membership of a group role
#                                                  (only when SKIP_ALTER_GROUP=false)
#   SKIP_DELETE=true                               never drop users (their configured access
#                                                  is revoked; the role is kept)
#   RECONCILE_ALLOW_EMPTY=true                     accept an answer where no read/write
#                                                  group has any member (otherwise refused
#                                                  while managed users exist)
#   RECONCILE_STATEMENT_TIMEOUT=300s               upper bound for one run's database side
#
# The managed population follows the configuration: a user with no read or write permission
# is dropped, also when a PSQL_* mapping is removed and the user was only in it. A
# PSQL_ALTER_GROUP mapping only manages group membership: it never creates a user, and a user
# who is only in an alter-group LDAP group is not kept.
#   LDAP_HOST (or LDAP_URI + LDAP_PORT), LDAP_USER, LDAP_PASSWORD, LDAP_GROUPS (base DN)
#
# Fails closed: LDAP unreachable, a failed bind, an incomplete search, a configured group
# that does not exist, or a username it cannot trust stops the run before the database is
# touched. A group that exists with no members is a valid answer. On the database side a
# failure on one user (a role that cannot be dropped, a conflicting grant) skips that user
# and is reported; everyone else is still reconciled.
#
# Exit status: 0 applied (or nothing to do), 1 configuration or LDAP error (nothing changed),
# 2 database error (nothing changed), 3 applied except for the users reported as ERROR.

set -u

ENV_FILE="${RECONCILE_ENV_FILE:-/local/application.env}"
if [ -f "$ENV_FILE" ]; then
	# Rendered at runtime by the scheduler; nothing to follow. Exported, so the PSQL_* lines in
	# it count: the configuration below is read from the environment.
	set -a
	# shellcheck source=/dev/null
	. "$ENV_FILE"
	set +a
fi

DEBUG=${DEBUG:-false}
RECONCILE_SOURCE="${RECONCILE_SOURCE:-cron}"   # boot | cron | manual
LDAP_NETTIMEOUT="${LDAP_NETTIMEOUT:-10}"
SKIP_DELETE="${SKIP_DELETE:-false}"
SKIP_ALTER_GROUP="${SKIP_ALTER_GROUP:-true}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-postgres}"
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-postgres}"
# The last run only: each run starts the file afresh.
LOG_FILE="${RECONCILE_LOG_FILE:-/var/log/reconcile_permissions.log}"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"
	if [ "$DEBUG" = true ] || [ "$RECONCILE_SOURCE" != cron ]; then
		printf '[psql_reconcile_permissions] %s\n' "$*"
	fi
}
# Errors always reach stderr, even when the caller ignores the exit status, and the server
# log as a WARNING (best effort), so they show in the container log: cron cannot write to
# PID 1's output here, the server runs as postgres.
report() { # message
	printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE"
	printf '[psql_reconcile_permissions] ERROR: %s\n' "$1" >&2
	# psql interpolates :'message' only in input it reads, not in -c.
	PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql -X -q -U "$POSTGRES_ADMIN_USER" -d "${POSTGRES_DEFAULT_DATABASE:-postgres}" \
		-v message="psql_reconcile_permissions (${RECONCILE_SOURCE}): $1" >/dev/null 2>&1 <<'SQL' || true
SELECT set_config('reconcile.message', :'message', false);
DO $$ BEGIN RAISE WARNING '%', current_setting('reconcile.message'); END $$;
SQL
}
fail() { # status message
	report "$2"
	exit "$1"
}
psql_admin() { # extra psql arguments
	PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DEFAULT_DATABASE" "$@"
}

# LDAP_HOST is host:port; older deployments give LDAP_URI and LDAP_PORT, sometimes with a scheme.
if [ -z "${LDAP_HOST:-}" ] && [ -n "${LDAP_URI:-}" ]; then
	LDAP_HOST="${LDAP_URI}:${LDAP_PORT:-389}"
fi
LDAP_HOST="${LDAP_HOST:-}"
# A configured scheme is kept (ldaps:// stays TLS); a bare host:port is ldap://.
case "$LDAP_HOST" in
	ldap://*|ldaps://*) LDAP_URL="$LDAP_HOST" ;;
	*) LDAP_URL="ldap://${LDAP_HOST}" ;;
esac

log "start (source=${RECONCILE_SOURCE})"

# The desired configuration. A key splits at its first _TABLE_.
CONFIG_SPEC=$(env | awk -F= -v alter="$SKIP_ALTER_GROUP" '
	function emit(kind, object, table, value,    group_count, group_names, position, group_name, emitted) {
		emitted = 0
		group_count = split(value, group_names, ",")
		for (position = 1; position <= group_count; position++) {
			group_name = group_names[position]; gsub(/^[ \t]+|[ \t]+$/, "", group_name)
			if (group_name != "") { printf "%s\t%s\t%s\t%s\n", kind, tolower(object), tolower(table), group_name; emitted = 1 }
		}
		# A variable with no group (an empty value rendered from a template) is an error,
		# not "nobody": it would silently remove that permission from everyone.
		if (!emitted) printf "empty\t%s\t%s\t-\n", tolower(object), tolower(table)
	}
	/^PSQL_(READ|WRITE)_SCHEMA_/ {
		kind = ($1 ~ /^PSQL_READ_/) ? "read" : "write"
		key = $1; sub(/^PSQL_(READ|WRITE)_SCHEMA_/, "", key)
		value = substr($0, length($1) + 2)
		table = ""
		separator = index(key, "_TABLE_")
		if (separator > 0) { table = substr(key, separator + 7); key = substr(key, 1, separator - 1) }
		emit(kind, key, table, value)
	}
	/^PSQL_ALTER_GROUP_/ && alter == "false" {
		key = $1; sub(/^PSQL_ALTER_GROUP_/, "", key)
		emit("member", key, "", substr($0, length($1) + 2))
	}
' | sort -u)

if [ -z "$CONFIG_SPEC" ]; then
	log "no PSQL_* permissions configured; nothing to reconcile"
	exit 0
fi
BAD=$(printf '%s\n' "$CONFIG_SPEC" | awk -F'\t' '
	$1 == "empty" { print "a PSQL_* variable for " $2 ($3 != "" ? "." $3 : "") " names no LDAP group"; next }
	($1 == "read" || $1 == "write") && ($2 ~ /^pg_/ || $2 == "information_schema" || $2 == "ldap_reconcile") { print "system schema " $2 " cannot be configured"; next }
	$2 !~ /^[a-z_][a-z0-9_]*$/ || ($3 != "" && $3 !~ /^[a-z_][a-z0-9_]*$/) || $4 !~ /^[A-Za-z0-9._-]+$/ { print }
	$1 == "write" && $3 != "" { print "write on a single table is not supported: " $0 }')
[ -z "$BAD" ] || fail 1 "invalid PSQL_* configuration: $(printf '%s' "$BAD" | tr '\n\t' '; ')"
LDAP_GROUP_NAMES=$(printf '%s\n' "$CONFIG_SPEC" | cut -f4 | sort -u)
GROUP_COUNT=$(printf '%s\n' "$LDAP_GROUP_NAMES" | wc -l | tr -d ' ')

[ -n "${LDAP_HOST}" ] || fail 1 "missing LDAP_HOST (or LDAP_URI)"
[ -n "${LDAP_USER:-}" ] || fail 1 "missing LDAP_USER"
[ -n "${LDAP_PASSWORD:-}" ] || fail 1 "missing LDAP_PASSWORD"
[ -n "${LDAP_GROUPS:-}" ] || fail 1 "missing LDAP_GROUPS"
[ -n "${POSTGRES_DEFAULT_DATABASE:-}" ] || fail 1 "missing POSTGRES_DEFAULT_DATABASE"

# A read-only replica follows its primary's catalog: nothing to do there.
IN_RECOVERY=$(psql_admin -tA -c "SELECT pg_is_in_recovery()") || fail 2 "cannot query the database"
if [ "$IN_RECOVERY" = t ]; then
	log "read-only replica; skipping"
	exit 0
fi
# The function must be the admin's, in the admin's schema: anything else is not run.
FUNCTION_INSTALLED=$(psql_admin -tA -c "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	WHERE n.nspname = 'ldap_reconcile' AND p.proname = 'reconcile_permissions' AND p.pronargs = 6
	  AND p.proowner = (SELECT oid FROM pg_roles WHERE rolname = current_user) AND n.nspowner = p.proowner") \
	|| fail 2 "cannot query the database"
[ "$FUNCTION_INSTALLED" = 1 ] || fail 2 "ldap_reconcile.reconcile_permissions() is not installed, or not owned by ${POSTGRES_ADMIN_USER} (psql_configure.sh installs it)"

# The bind password goes through a private file, not argv (visible to every process).
LDAP_PASSWORD_FILE=$(mktemp) || fail 1 "cannot create a temporary file"
trap 'rm -f "$LDAP_PASSWORD_FILE"' EXIT
chmod 600 "$LDAP_PASSWORD_FILE"
printf '%s' "$LDAP_PASSWORD" > "$LDAP_PASSWORD_FILE"
ldap_search() { # base scope filter attributes...
	base=$1; scope=$2; filter=$3; shift 3
	# nettimeout bounds the connection; -l and LDAPTIMEOUT bound a server that
	# accepts it and then stalls.
	LDAPTIMEOUT=${LDAP_NETTIMEOUT} ldapsearch -LLL -x -o "nettimeout=${LDAP_NETTIMEOUT}" -l "${LDAP_NETTIMEOUT}" -o ldif-wrap=no \
		-H "$LDAP_URL" -D "$LDAP_USER" -y "$LDAP_PASSWORD_FILE" -b "$base" -s "$scope" "$filter" "$@"
}

# Reachability, bind and base DN, apart from the group search.
ldap_search "$LDAP_GROUPS" base "(objectClass=*)" dn > /dev/null 2>> "$LOG_FILE" \
	|| fail 1 "LDAP bind or base DN check failed at ${LDAP_URL} (base ${LDAP_GROUPS})"

# One search for every configured group. A non-zero status (size or time limit, referral,
# server error) means the answer may be incomplete.
FILTER="(|$(printf '%s\n' "$LDAP_GROUP_NAMES" | sed 's/.*/(cn=&)/' | tr -d '\n'))"
LDIF=$(ldap_search "$LDAP_GROUPS" sub "$FILTER" cn objectClass memberUid 2>> "$LOG_FILE") \
	|| fail 1 "LDAP group search failed (status $?); filter ${FILTER}"

# Entries as "group<TAB>member" lines ("group<TAB>" for a group without members). Attribute
# names are matched without case. Values in base64 (attr::) are not plain names, and an entry
# that is not a posixGroup (groupOfNames has member, not memberUid) cannot be read as one:
# both are refused rather than read as empty.
MEMBERSHIP=$(printf '%s\n' "$LDIF" | awk '
	function flush(    position) {
		if (dn == 0) return
		if (cn == "") { print "NOCN\t"; return }
		if (!posix) { printf "NOTPOSIX\t%s\n", cn; return }
		printf "%s\t\n", cn
		for (position = 1; position <= count; position++) printf "%s\t%s\n", cn, member[position]
	}
	{ name = tolower($0); sub(/:.*/, "", name) }
	name == "dn" { flush(); dn = 1; cn = ""; count = 0; posix = 0; next }
	/^[A-Za-z]+::/ { print "BASE64\t" $0; next }
	name == "cn" { cn = substr($0, index($0, ":") + 2); next }
	name == "objectclass" { if (tolower(substr($0, index($0, ":") + 2)) == "posixgroup") posix = 1; next }
	name == "memberuid" { member[++count] = substr($0, index($0, ":") + 2); next }
	END { flush() }
')
case "$MEMBERSHIP" in
	*BASE64*) fail 1 "LDAP returned base64-encoded values; refusing to guess names" ;;
esac
NOT_POSIX=$(printf '%s\n' "$MEMBERSHIP" | awk -F'\t' '$1 == "NOTPOSIX" || $1 == "NOCN" { print $2 }')
[ -z "$NOT_POSIX" ] || fail 1 "LDAP groups that are not posixGroup entries (no memberUid to read): $(printf '%s' "$NOT_POSIX" | tr '\n' ' ')"

# Every configured group must come back exactly once.
for group in $LDAP_GROUP_NAMES; do
	found=$(printf '%s\n' "$MEMBERSHIP" | awk -F'\t' -v wanted="$group" '$1 == wanted && $2 == "" { entries++ } END { print entries + 0 }')
	[ "$found" = 1 ] || fail 1 "LDAP group ${group} came back ${found} times (expected exactly once under ${LDAP_GROUPS})"
done
MEMBERS=$(printf '%s\n' "$MEMBERSHIP" | awk -F'\t' '$2 != ""' | sort -u)
INVALID=$(printf '%s\n' "$MEMBERS" | awk -F'\t' '$2 != "" && $2 !~ /^[a-z_][a-z0-9_.-]*$/ { print $2 }' | sort -u)
[ -z "$INVALID" ] || fail 1 "LDAP returned usernames that are not valid role names: $(printf '%s' "$INVALID" | tr '\n' ' ')"

USER_COUNT=$(printf '%s\n' "$MEMBERS" | cut -f2 | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
log "LDAP: ${GROUP_COUNT} group(s), ${USER_COUNT} user(s)"

# No member in any read/write group would drop (or revoke) every managed user. Single empty
# groups are normal (temporary permissions); all of them empty at once is more likely a
# directory that stopped answering memberUid, so it needs RECONCILE_ALLOW_EMPTY=true. On the
# first run (no ldap_managed yet) with drops enabled, the legacy users about to be adopted
# would be dropped in the same run, so that is refused as well.
PERMISSION_GROUPS=$(printf '%s\n' "$CONFIG_SPEC" | awk -F'\t' '$1 == "read" || $1 == "write" { print $4 }' | sort -u | tr '\n' ' ')
PERMISSION_USER_COUNT=$(printf '%s\n' "$MEMBERS" | awk -F'\t' -v groups=" ${PERMISSION_GROUPS}" '$2 != "" && index(groups, " " $1 " ") { print $2 }' \
	| sort -u | wc -l | tr -d ' ')
if [ "$PERMISSION_USER_COUNT" = 0 ] && [ "${RECONCILE_ALLOW_EMPTY:-false}" != true ]; then
	# -1: first run, ldap_managed does not exist yet.
	MANAGED_COUNT=$(psql_admin -tA -c "SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ldap_managed') THEN -1
		ELSE (SELECT count(*) FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid WHERE r.rolname = 'ldap_managed') END") \
		|| fail 2 "cannot query the database"
	if [ "$MANAGED_COUNT" = -1 ] && [ "$SKIP_DELETE" != true ]; then
		fail 1 "no configured read/write LDAP group has any member on the first run; refusing to adopt and drop the existing users (set RECONCILE_ALLOW_EMPTY=true if this is intended)"
	fi
	[ "$MANAGED_COUNT" = 0 ] || [ "$MANAGED_COUNT" = -1 ] \
		|| fail 1 "no configured read/write LDAP group has any member, and ${MANAGED_COUNT} managed user(s) exist; refusing (set RECONCILE_ALLOW_EMPTY=true if this is intended)"
fi

ALLOW_DROPS=true
[ "$SKIP_DELETE" = true ] && ALLOW_DROPS=false
PROTECTED="${POSTGRES_ADMIN_USER},${POSTGRES_DEFAULT_USER:-},${POSTGRES_REPLICATOR_USER:-}"

RESULT=$(psql_admin -tA -F ' ' \
	-v config="$CONFIG_SPEC" -v members="$MEMBERS" -v source="$RECONCILE_SOURCE" \
	-v owner="${POSTGRES_DEFAULT_USER:-}" -v allow_drops="$ALLOW_DROPS" -v protected="$PROTECTED" \
	-v statement_timeout="${RECONCILE_STATEMENT_TIMEOUT:-300s}" 2>&1 <<'SQL'
SET statement_timeout = :'statement_timeout';
SET lock_timeout = '30s';
SELECT action, coalesce(username, '-'), coalesce(detail, '')
  FROM ldap_reconcile.reconcile_permissions(:'config', :'members', :'source', :'owner', :'allow_drops'::boolean,
                             array_remove(string_to_array(:'protected', ','), ''));
SQL
) || fail 2 "reconcile failed, nothing was changed: $(printf '%s' "$RESULT" | tr '\n' ' ')"

if [ -n "$RESULT" ]; then
	printf '%s\n' "$RESULT" | while IFS= read -r line; do log "$line"; done
fi
log "done: $(printf '%s\n' "$RESULT" | sed '/^$/d' | awk '{ per_action[$1]++ } END { summary = ""; for (action in per_action) summary = summary action "=" per_action[action] " "; print (summary == "" ? "no changes" : summary) }')"
ERRORS=$(printf '%s\n' "$RESULT" | awk '$1 == "ERROR"')
if [ -n "$ERRORS" ]; then
	report "applied except for: $(printf '%s' "$ERRORS" | tr '\n' ';')"
	exit 3
fi
exit 0
