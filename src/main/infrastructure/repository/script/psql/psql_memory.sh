#!/bin/sh

# Out-of-memory handling of the server, sourced by the init scripts and by psql_memory_guard.sh.
# Defines functions only; sourcing it runs nothing and cannot fail.
#
# How the init scripts use it (psql_init.sh and psql_replica_init.sh, just before the final exec;
# they run under errexit, so neither step may stop a boot):
#
#   . ./psql_memory.sh
#   psql_oom_target || true
#   if [ "$(id -u)" = 0 ]
#   then
#   	gosu postgres ./psql_memory_guard.sh &
#   else
#   	./psql_memory_guard.sh &
#   fi
#
# psql_oom_target exports PG_OOM_ADJUST_FILE and PG_OOM_ADJUST_VALUE (or unsets both when off) in
# the calling shell, which then execs into the postmaster, and logs the boot lines. It always
# returns 0. psql_memory_guard.sh runs the guard loop in the background; it always exits 0.
#
# Inside a container the kernel kills a process once the container's memory limit is reached.
# Whatever it kills, the database pays dearly: a server process killed by a signal makes the
# postmaster end every other session and run crash recovery, refusing connections meanwhile, and
# thousands of clients then reconnect at once, which can bring the next kill. Two things here:
#
#  - The memory guard (memory_guard_main, run by psql_memory_guard.sh): before the limit is
#    reached it ends the sessions holding the most private memory, idle ones first, so the kernel
#    does not have to kill anything. Ending a session this way costs that session only. It only
#    ever calls pg_cancel_backend and pg_terminate_backend; it never sends a signal itself.
#  - OOM targeting (psql_oom_target): every process the postmaster starts raises its own
#    oom_score_adj (PostgreSQL writes PG_OOM_ADJUST_VALUE to PG_OOM_ADJUST_FILE after fork), so
#    when the kernel does kill, the victim is a server process and not the postmaster. It only
#    makes that choice deterministic: any kill still means crash recovery. It cannot help when the
#    runtime sets memory.oom.group=1: the kernel then kills every process of the cgroup together.
#
# Logging: one line per event on stderr, in English whatever the server's locale:
#   <YYYY-MM-DD HH:MM:SS TZ> [<pid>] MEMORY_GUARD: <LEVEL>: event=<name> key=value ...
# String values are double-quoted, with inner double quotes replaced by single ones.
#
# Memory is read from the container's cgroup: v2 memory.current, memory.max, memory.stat and
# memory.events, or v1 memory.usage_in_bytes, memory.limit_in_bytes, memory.stat and
# memory.oom_control. The file page cache (active_file and inactive_file) is left out of the use:
# the kernel reclaims it before killing anything, and a database keeps it full.
#
# Guard settings (environment, checked once at start; bad values fall back with a WARN):
#   MEMORY_GUARD_ENABLED          true          false: one line, exit 0.
#   MEMORY_GUARD_MODE             dry-run       enforce signals; dry-run logs result=dry-run only.
#   MEMORY_GUARD_INTERVAL         2             seconds between passes below the first threshold.
#   MEMORY_GUARD_FAST_INTERVAL    0.5           seconds between passes at or above it.
#   MEMORY_GUARD_MAX_INTERVAL     5             longest interval self-throttling may reach.
#   MEMORY_GUARD_TICK_BUDGET_MS   200           a pass longer than this throttles the guard.
#   MEMORY_GUARD_IDLE_PERC        85            stage idle.
#   MEMORY_GUARD_ACTIVE_PERC      92            stage active.
#   MEMORY_GUARD_CRITICAL_PERC    96            stage critical.
#   MEMORY_GUARD_IDLE_BATCH       5             idle terminations per pass.
#   MEMORY_GUARD_IDLE_MAX_PER_MIN 120           rolling cap on stage idle; 0 is no cap.
#   MEMORY_GUARD_CRITICAL_BATCH   10            terminations per pass in stage critical.
#   MEMORY_GUARD_CANCEL_GRACE     1             seconds between a cancel and a terminate.
#   MEMORY_GUARD_MIN_PRIVATE_MB   CONNECTION_MEMORY / 1024 (16)  smaller sessions are never ended.
#   MEMORY_GUARD_EXCLUDE_USERS    (empty)       comma list of roles never ended.
#   MEMORY_GUARD_QUERY_CHARS      120           query prefix in action lines; 0 logs none.
#   MEMORY_GUARD_STATUS_INTERVAL  300           seconds between status lines; 0 is off.
#   MEMORY_GUARD_PAUSE_FILE       /tmp/memory_guard.pause  while it exists (owned by postgres or
#                                               root) nothing is signalled.
# OOM targeting: OOM_TARGETING_ENABLED (true), OOM_CHILD_SCORE_ADJ (100, -1000 to 1000).
# The guard connects as POSTGRES_ADMIN_USER over the local socket (MEMORY_GUARD_SOCKET_DIR,
# /var/run/postgresql), with PGPASSWORD only when POSTGRES_ADMIN_PASSWORD is set, never prompting.
# Tests point MEMORY_CGROUP_DIR, MEMORY_PROC_DIR and MEMORY_UPTIME_FILE at fakes.

# Tab, the field separator of every list below.
MEMORY_TAB=$(printf '\t')

# Logs one line to stderr: memory_log <level> <event> [key=value ...].
memory_log() { # level event fields
	memory_log_level=$1
	memory_log_event=$2
	shift 2
	if [ $# -gt 0 ]
	then
		printf '%s\n' "$(memory_log_prefix) ${memory_log_level}: event=${memory_log_event} $*" >&2
	else
		printf '%s\n' "$(memory_log_prefix) ${memory_log_level}: event=${memory_log_event}" >&2
	fi
}

# The start of a log line, up to and including the tag.
memory_log_prefix() {
	echo "$(date '+%Y-%m-%d %H:%M:%S %Z') [$$] MEMORY_GUARD:"
}

# Prints $1 as a quoted log value: one line, double quotes made single, at most 512 characters.
memory_quote() { # value
	printf '"%s"' "$(printf '%s' "$1" | tr '\n\r\t"' "   '" | cut -c 1-512)"
}

# Prints key=value, quoting the value unless it is a plain token.
memory_field() { # key value
	case "$2" in
		''|*[!A-Za-z0-9_.:/+-]*) printf '%s\n' "$1=$(memory_quote "$2")" ;;
		*) printf '%s\n' "$1=$2" ;;
	esac
}

# One WARN line for a setting that was invalid or clamped.
memory_setting_warn() { # name value used reason
	memory_log WARN setting "name=$1" "value=$(memory_quote "$2")" "$(memory_field used "$3")" "reason=$(memory_quote "$4")"
}

# Settings come from the environment (the image's ENV block, or docker run -e): read by name with
# printenv and written back with export, so no setting's value is ever evaluated as code.
memory_env() { # variable
	printenv "$1" 2>/dev/null || true
}

# Checks the integer setting named $1 in place: $2 when empty or not an integer, clamped to $3..$4.
# Keeps every later arithmetic expansion valid whatever the environment holds.
memory_setting() { # variable default min max
	memory_setting_given=$(memory_env "$1")
	memory_setting_value=${memory_setting_given:-$2}
	memory_setting_sign=
	case "${memory_setting_value}" in -*) memory_setting_sign=- ;; esac
	memory_setting_digits=${memory_setting_value#-}
	case "${memory_setting_digits}" in
		''|*[!0-9]*)
			memory_setting_warn "$1" "${memory_setting_given}" "$2" "not an integer"
			memory_setting_value=$2
			;;
		*)
			# No leading zeros (octal in arithmetic), and no more digits than arithmetic holds.
			memory_setting_digits=${memory_setting_digits#"${memory_setting_digits%%[!0]*}"}
			memory_setting_digits=${memory_setting_digits:-0}
			if [ "${#memory_setting_digits}" -gt 9 ]
			then
				memory_setting_digits=999999999
			fi
			memory_setting_value=${memory_setting_sign}${memory_setting_digits}
			if [ "${memory_setting_value}" -lt "$3" ]
			then
				memory_setting_warn "$1" "${memory_setting_given}" "$3" "below the minimum"
				memory_setting_value=$3
			elif [ "${memory_setting_value}" -gt "$4" ]
			then
				memory_setting_warn "$1" "${memory_setting_given}" "$4" "above the maximum"
				memory_setting_value=$4
			fi
			;;
	esac
	export "$1=${memory_setting_value}"
}

# Checks the duration in seconds named $1 in place (a positive number with at most one decimal
# point, $2 otherwise) and sets <name>_MS to it in milliseconds.
memory_seconds() { # variable default
	memory_seconds_given=$(memory_env "$1")
	memory_seconds_value=${memory_seconds_given:-$2}
	case "${memory_seconds_value}" in
		*[!0-9.]*|*.*.*|.|'')
			memory_setting_warn "$1" "${memory_seconds_given}" "$2" "not a positive number of seconds"
			memory_seconds_value=$2
			;;
	esac
	memory_seconds_int=${memory_seconds_value%%.*}
	memory_seconds_frac=
	case "${memory_seconds_value}" in *.*) memory_seconds_frac=${memory_seconds_value#*.} ;; esac
	memory_seconds_frac="${memory_seconds_frac}000"
	memory_seconds_frac=${memory_seconds_frac%"${memory_seconds_frac#???}"}
	memory_seconds_int=${memory_seconds_int#"${memory_seconds_int%%[!0]*}"}
	memory_seconds_frac=${memory_seconds_frac#"${memory_seconds_frac%%[!0]*}"}
	if [ "${#memory_seconds_int}" -gt 6 ]
	then
		memory_seconds_int=999999
	fi
	memory_seconds_ms=$(( ${memory_seconds_int:-0} * 1000 + ${memory_seconds_frac:-0} ))
	if [ "${memory_seconds_ms}" -le 0 ]
	then
		memory_setting_warn "$1" "${memory_seconds_given}" "$2" "not a positive number of seconds"
		export "$1=$2"
		memory_seconds "$1" "$2"
		return 0
	fi
	export "$1=${memory_seconds_value}" "$1_MS=${memory_seconds_ms}"
}

# Checks the boolean setting named $1 in place: true or false, $2 otherwise.
memory_bool() { # variable default
	memory_bool_given=$(memory_env "$1")
	case "${memory_bool_given}" in
		true|false) ;;
		'') export "$1=$2" ;;
		*)
			memory_setting_warn "$1" "${memory_bool_given}" "$2" "not true or false"
			export "$1=$2"
			;;
	esac
}

# Tells whether the pause file is there and owned by the guard's own user or by root: /tmp is
# writable by anyone, and another account's file must not stop the guard.
memory_guard_paused() {
	[ -e "${MEMORY_GUARD_PAUSE_FILE}" ] || return 1
	memory_guard_pause_owner=$(stat -c %u "${MEMORY_GUARD_PAUSE_FILE}" 2>/dev/null) || return 1
	[ "${memory_guard_pause_owner}" = 0 ] || [ "${memory_guard_pause_owner}" = "$(id -u)" ]
}

# Milliseconds since boot, in memory_now_ms, from /proc/uptime with no process started.
memory_now() {
	memory_now_up=
	if [ -r "${MEMORY_UPTIME_FILE:-/proc/uptime}" ]
	then
		read -r memory_now_up _ < "${MEMORY_UPTIME_FILE:-/proc/uptime}" || memory_now_up=
	fi
	case "${memory_now_up}" in
		[0-9]*.[0-9][0-9])
			memory_now_ms=$(( ${memory_now_up%.*} * 1000 + 1${memory_now_up#*.} * 10 - 1000 ))
			;;
		*)
			memory_now_ms=$(( $(date +%s) * 1000 ))
			;;
	esac
}

# Sleeps the given milliseconds.
memory_sleep() { # ms
	memory_sleep_rest=$(( $1 % 1000 ))
	case "${#memory_sleep_rest}" in
		1) memory_sleep_rest=00${memory_sleep_rest} ;;
		2) memory_sleep_rest=0${memory_sleep_rest} ;;
	esac
	sleep "$(( $1 / 1000 )).${memory_sleep_rest}" 2>/dev/null || sleep $(( $1 / 1000 + 1 )) || true
}

# Finds the container's memory cgroup: sets MEMORY_CGROUP to v2, v1 or none and MEMORY_CGROUP_PATH
# to its folder. MEMORY_CGROUP_DIR is the cgroup mount (tests point it elsewhere).
memory_cgroup() {
	MEMORY_CGROUP_DIR=${MEMORY_CGROUP_DIR:-/sys/fs/cgroup}
	if [ -r "${MEMORY_CGROUP_DIR}/memory.current" ] && [ -r "${MEMORY_CGROUP_DIR}/memory.max" ]
	then
		MEMORY_CGROUP=v2
		MEMORY_CGROUP_PATH=${MEMORY_CGROUP_DIR}
	elif [ -r "${MEMORY_CGROUP_DIR}/memory/memory.usage_in_bytes" ] && [ -r "${MEMORY_CGROUP_DIR}/memory/memory.limit_in_bytes" ]
	then
		MEMORY_CGROUP=v1
		MEMORY_CGROUP_PATH=${MEMORY_CGROUP_DIR}/memory
	else
		MEMORY_CGROUP=none
		MEMORY_CGROUP_PATH=
	fi
}

# Reads the cgroup once, with one awk. Prints
#   <used %> <used MB> <limit MB> <oom kills> <used kB> <limit kB>
# or "unlimited" when the cgroup has no limit (v2 "max", v1 a page-rounded 2^63), or nothing when
# it cannot be read. The oom kill count is -1 when the kernel does not report it.
# v1 memory.stat carries both the cgroup's own counters and the hierarchical total_* ones; the use
# (memory.usage_in_bytes) is hierarchical, so only total_* are subtracted when present. Adding both
# would leave the page cache out twice and make the guard act late.
memory_read() {
	case "${MEMORY_CGROUP}" in
		v2)
			set -- "${MEMORY_CGROUP_PATH}/memory.max" "${MEMORY_CGROUP_PATH}/memory.current" "${MEMORY_CGROUP_PATH}/memory.stat"
			[ -r "${MEMORY_CGROUP_PATH}/memory.events" ] && set -- "$@" "${MEMORY_CGROUP_PATH}/memory.events"
			;;
		v1)
			set -- "${MEMORY_CGROUP_PATH}/memory.limit_in_bytes" "${MEMORY_CGROUP_PATH}/memory.usage_in_bytes" "${MEMORY_CGROUP_PATH}/memory.stat"
			[ -r "${MEMORY_CGROUP_PATH}/memory.oom_control" ] && set -- "$@" "${MEMORY_CGROUP_PATH}/memory.oom_control"
			;;
		*) return 1 ;;
	esac
	awk '
		BEGIN { oom = -1 }
		FILENAME ~ /(memory\.max|memory\.limit_in_bytes)$/ && FNR == 1 { limit = $1 }
		FILENAME ~ /(memory\.current|memory\.usage_in_bytes)$/ && FNR == 1 { current = $1 }
		FILENAME ~ /memory\.stat$/ {
			if ($1 == "active_file" || $1 == "inactive_file") own += $2
			else if ($1 == "total_active_file" || $1 == "total_inactive_file") { total += $2; hierarchical = 1 }
		}
		FILENAME ~ /(memory\.events|memory\.oom_control)$/ && $1 == "oom_kill" { oom = $2 }
		END {
			if (limit == "max" || (limit ~ /^[0-9]+$/ && limit + 0 >= 1152921504606846976)) { print "unlimited"; exit 0 }
			if (limit !~ /^[0-9]+$/ || limit + 0 <= 0 || current !~ /^[0-9]+$/) exit 1
			if (oom !~ /^-?[0-9]+$/) oom = -1
			used = current - (hierarchical ? total : own)
			if (used < 0) used = 0
			printf "%d %.0f %.0f %d %.0f %.0f\n", int(used * 100 / limit), used / 1048576, limit / 1048576, oom, used / 1024, limit / 1024
		}' "$@" 2>/dev/null
}

# Reads the first word of a cgroup file into memory_value, or "unknown".
memory_cgroup_value() { # file
	memory_value=
	if [ -r "$1" ]
	then
		read -r memory_value _ < "$1" || true
	fi
	case "${memory_value}" in
		''|*[!A-Za-z0-9_.-]*) memory_value=unknown ;;
	esac
}

# Sets up the OOM targeting for the server about to start, and logs it. Exports
# PG_OOM_ADJUST_FILE and PG_OOM_ADJUST_VALUE, which every process the postmaster forks applies to
# itself. Raising oom_score_adj needs no privilege; lowering it below the inherited value does
# (CAP_SYS_RESOURCE), which is why the postmaster keeps what it inherits and its children go up.
# 100 rather than more: inside the container any positive value puts the children first, and on a
# host-level OOM a higher value would make this database the host's first victim. Always returns 0.
psql_oom_target() {
	memory_bool OOM_TARGETING_ENABLED true
	memory_setting OOM_CHILD_SCORE_ADJ 100 -1000 1000
	memory_cgroup
	# This shell is the future postmaster (the init script execs into it); read is a builtin, so
	# /proc/self is this shell.
	memory_cgroup_value "${MEMORY_PROC_DIR:-/proc}/self/oom_score_adj"
	case "${memory_value}" in
		-[0-9]*|[0-9]*) oom_target_postmaster=${memory_value} ;;
		*) oom_target_postmaster=unknown ;;
	esac
	oom_target_max=unknown
	oom_target_high=unknown
	oom_target_swap=unknown
	oom_target_group=unknown
	case "${MEMORY_CGROUP}" in
		v2)
			memory_cgroup_value "${MEMORY_CGROUP_PATH}/memory.max"; oom_target_max=${memory_value}
			memory_cgroup_value "${MEMORY_CGROUP_PATH}/memory.high"; oom_target_high=${memory_value}
			memory_cgroup_value "${MEMORY_CGROUP_PATH}/memory.swap.max"; oom_target_swap=${memory_value}
			memory_cgroup_value "${MEMORY_CGROUP_PATH}/memory.oom.group"; oom_target_group=${memory_value}
			;;
		v1)
			memory_cgroup_value "${MEMORY_CGROUP_PATH}/memory.limit_in_bytes"; oom_target_max=${memory_value}
			# cgroup v1 has no group kill.
			oom_target_group=0
			;;
	esac
	if [ "${OOM_TARGETING_ENABLED}" = "true" ]
	then
		export PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj
		export PG_OOM_ADJUST_VALUE="${OOM_CHILD_SCORE_ADJ}"
		oom_target_state=on
		oom_target_child=${OOM_CHILD_SCORE_ADJ}
	else
		unset PG_OOM_ADJUST_FILE PG_OOM_ADJUST_VALUE
		oom_target_state=off
		oom_target_child=${oom_target_postmaster}
	fi
	memory_log LOG oom_target "state=${oom_target_state}" "postmaster_oom_score_adj=${oom_target_postmaster}" \
		"child_oom_score_adj=${oom_target_child}" "cgroup=${MEMORY_CGROUP}" "memory_max=${oom_target_max}" \
		"memory_high=${oom_target_high}" "swap_max=${oom_target_swap}" "oom_group=${oom_target_group}" \
		'note="only makes the victim deterministic; any kill is crash recovery"'
	if [ "${oom_target_group}" = 1 ]
	then
		memory_log WARN oom_group oom_group=1
	fi
	if [ "${oom_target_state}" = on ] && [ "${oom_target_postmaster}" != unknown ] \
		&& [ "${OOM_CHILD_SCORE_ADJ}" -le "${oom_target_postmaster}" ]
	then
		memory_log WARN oom_target_ineffective "child_oom_score_adj=${OOM_CHILD_SCORE_ADJ}" "postmaster_oom_score_adj=${oom_target_postmaster}"
	fi
	return 0
}

# The guard's settings, read and checked once.
memory_guard_settings() {
	memory_bool MEMORY_GUARD_ENABLED true
	case "${MEMORY_GUARD_MODE:-}" in
		enforce|dry-run) ;;
		'') MEMORY_GUARD_MODE=dry-run ;;
		*)
			memory_setting_warn MEMORY_GUARD_MODE "${MEMORY_GUARD_MODE}" dry-run "not enforce or dry-run"
			MEMORY_GUARD_MODE=dry-run
			;;
	esac
	memory_seconds MEMORY_GUARD_INTERVAL 2
	memory_seconds MEMORY_GUARD_FAST_INTERVAL 0.5
	memory_seconds MEMORY_GUARD_MAX_INTERVAL 5
	memory_setting MEMORY_GUARD_TICK_BUDGET_MS 200 1 60000
	memory_setting MEMORY_GUARD_IDLE_PERC 85 1 100
	memory_setting MEMORY_GUARD_ACTIVE_PERC 92 1 100
	memory_setting MEMORY_GUARD_CRITICAL_PERC 96 1 100
	if [ "${MEMORY_GUARD_IDLE_PERC}" -gt "${MEMORY_GUARD_ACTIVE_PERC}" ] || [ "${MEMORY_GUARD_ACTIVE_PERC}" -gt "${MEMORY_GUARD_CRITICAL_PERC}" ]
	then
		memory_setting_warn MEMORY_GUARD_IDLE_PERC,MEMORY_GUARD_ACTIVE_PERC,MEMORY_GUARD_CRITICAL_PERC \
			"${MEMORY_GUARD_IDLE_PERC},${MEMORY_GUARD_ACTIVE_PERC},${MEMORY_GUARD_CRITICAL_PERC}" "85,92,96" "not in increasing order"
		MEMORY_GUARD_IDLE_PERC=85
		MEMORY_GUARD_ACTIVE_PERC=92
		MEMORY_GUARD_CRITICAL_PERC=96
	fi
	memory_setting MEMORY_GUARD_IDLE_BATCH 5 1 1000
	memory_setting MEMORY_GUARD_IDLE_MAX_PER_MIN 120 0 100000
	memory_setting MEMORY_GUARD_CRITICAL_BATCH 10 1 1000
	memory_setting MEMORY_GUARD_CANCEL_GRACE 1 0 60
	# What the tuner budgets per connection (CONNECTION_MEMORY, kB): a session under it is within
	# its budget and not worth ending.
	memory_guard_connection_mb=16
	case "${CONNECTION_MEMORY:-}" in
		''|*[!0-9]*) ;;
		?????????*) ;;
		*) memory_guard_connection_mb=$(( ${CONNECTION_MEMORY#"${CONNECTION_MEMORY%%[!0]*}"}0 / 10240 )) ;;
	esac
	memory_setting MEMORY_GUARD_MIN_PRIVATE_MB "${memory_guard_connection_mb}" 0 1048576
	memory_setting MEMORY_GUARD_QUERY_CHARS 120 0 1000
	memory_setting MEMORY_GUARD_STATUS_INTERVAL 300 0 86400
	MEMORY_GUARD_PAUSE_FILE=${MEMORY_GUARD_PAUSE_FILE:-/tmp/memory_guard.pause}
	MEMORY_GUARD_SOCKET_DIR=${MEMORY_GUARD_SOCKET_DIR:-/var/run/postgresql}
	MEMORY_PROC_DIR=${MEMORY_PROC_DIR:-/proc}
	# Roles never ended. Names are checked so they can be written into the SQL as they are.
	memory_guard_exclude=
	memory_guard_exclude_sql=
	memory_guard_exclude_rest="${MEMORY_GUARD_EXCLUDE_USERS:-},"
	while [ -n "${memory_guard_exclude_rest}" ]
	do
		memory_guard_exclude_name=${memory_guard_exclude_rest%%,*}
		memory_guard_exclude_rest=${memory_guard_exclude_rest#*,}
		case "${memory_guard_exclude_name}" in
			'') ;;
			*[!A-Za-z0-9_.-]*)
				memory_setting_warn MEMORY_GUARD_EXCLUDE_USERS "${memory_guard_exclude_name}" dropped "not a role name of letters, digits, _ . -"
				;;
			*)
				memory_guard_exclude="${memory_guard_exclude:+${memory_guard_exclude},}${memory_guard_exclude_name}"
				memory_guard_exclude_sql="${memory_guard_exclude_sql:+${memory_guard_exclude_sql}, }'${memory_guard_exclude_name}'"
				;;
		esac
	done
	MEMORY_GUARD_EXCLUDE_USERS=${memory_guard_exclude}
	if [ -n "${memory_guard_exclude_sql}" ]
	then
		memory_guard_exclude_sql=" AND a.usename::text NOT IN (${memory_guard_exclude_sql})"
	fi
	# Client backends that are not superusers (WAL senders and background processes have other
	# backend types), not excluded, not the guard's own session; plus parallel workers, only to
	# add their memory to the session leading them. backend_start in microseconds identifies the
	# session against pid reuse. Text is stripped of whitespace and control characters here. The
	# query prefix carries no values: before it is cut to MEMORY_GUARD_QUERY_CHARS, anything from a
	# dollar quote on becomes $?$, a quoted identifier holding a quote becomes "?", string literals
	# (E'' ones with their backslash escapes too) and numbers become ?, and comments go (query_id
	# names the statement). Kept in a quoted here-document so the SQL is written as is.
	memory_guard_mask_sql=$(cat <<'EOSQL'
regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
			coalesce(a.query, ''),
			'\$([A-Za-z_][A-Za-z0-9_]*)?\$.*', '$?$'),
			'"([^"]|"")*''([^"]|"")*("|$)', '"?"', 'g'),
			'[Ee]''(\\.|''''|[^''\\])*(''|$)', '?', 'g'),
			'''(''''|[^''])*(''|$)', '?', 'g'),
			'/\*.*?(\*/|$)', ' ', 'g'),
			'--[^\n]*', ' ', 'g'),
			'\m[0-9]+(\.[0-9]+)?\M', '?', 'g')
EOSQL
)
	MEMORY_GUARD_LIST_SQL="SELECT a.pid, coalesce(a.leader_pid, a.pid), a.backend_type, coalesce(a.state, ''),
		coalesce((extract(epoch FROM a.backend_start) * 1000000)::bigint, 0),
		regexp_replace(coalesce(a.usename::text, ''), '[[:space:][:cntrl:]]+', ' ', 'g'),
		regexp_replace(coalesce(a.datname::text, ''), '[[:space:][:cntrl:]]+', ' ', 'g'),
		regexp_replace(coalesce(a.application_name, ''), '[[:space:][:cntrl:]]+', ' ', 'g'),
		coalesce(a.query_id::text, ''),
		regexp_replace(left(${memory_guard_mask_sql}, ${MEMORY_GUARD_QUERY_CHARS}), '[[:space:][:cntrl:]]+', ' ', 'g')
		FROM pg_stat_activity a LEFT JOIN pg_roles r ON r.oid = a.usesysid
		WHERE a.pid <> pg_backend_pid()
			AND ((a.backend_type = 'client backend' AND r.rolsuper IS FALSE${memory_guard_exclude_sql}) OR a.backend_type = 'parallel worker')"
	# The same for stage idle: idle client backends only (an idle session leads no parallel worker).
	MEMORY_GUARD_LIST_IDLE_SQL="${MEMORY_GUARD_LIST_SQL%%WHERE *}WHERE a.pid <> pg_backend_pid() AND a.state = 'idle'
			AND a.backend_type = 'client backend' AND r.rolsuper IS FALSE${memory_guard_exclude_sql}"
	if [ -n "${POSTGRES_ADMIN_PASSWORD:-}" ]
	then
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD}
		export PGPASSWORD
	fi
}

# Runs one statement as the admin user over the local socket, one row per line, fields split by
# tabs. Bounded in time so a stuck server cannot stop the guard; never prompts for a password.
memory_guard_psql() { # sql
	PGAPPNAME=psql_memory_guard PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=1000' PGCONNECT_TIMEOUT=3 \
		timeout 10 psql -X -q -w -A -t -F "${MEMORY_TAB}" -v ON_ERROR_STOP=1 \
		-h "${MEMORY_GUARD_SOCKET_DIR}" -U "${POSTGRES_ADMIN_USER:-postgres}" -d postgres -c "$1"
}

# Lists the sessions the guard may end into <state>/ranking, largest first, one per line:
#   <private kB> <pid> <backend_start> <state> <user> <database> <application> <query_id> <query>
# and the number of server processes listed into <state>/listed. Private memory is RssAnon + VmPTE
# from /proc/<pid>/status: the backend's own heap (work_mem, caches) and its page tables, leaving
# out the shared buffers it maps; a parallel worker's is added to its leader's. Only the status
# files of the listed client backends and their parallel workers are read, never all of /proc;
# status is a counter read, unlike smaps_rollup, which walks every mapping.
memory_guard_scan() { # all|idle
	memory_guard_dir=${MEMORY_GUARD_STATE_DIR}
	memory_guard_list_sql=${MEMORY_GUARD_LIST_SQL}
	[ "${1:-all}" = idle ] && memory_guard_list_sql=${MEMORY_GUARD_LIST_IDLE_SQL}
	if ! memory_guard_psql "${memory_guard_list_sql}" > "${memory_guard_dir}/rows" 2> "${memory_guard_dir}/psql.err"
	then
		return 1
	fi
	awk -F '\t' -v proc="${MEMORY_PROC_DIR}" '
		$1 !~ /^[0-9]+$/ { next }
		$3 == "client backend" { client[$1] = 1; print proc "/" $1 "/status"; next }
		$3 == "parallel worker" { worker[$1] = $2 }
		END { for (pid in worker) if (worker[pid] in client) print proc "/" pid "/status" }' "${memory_guard_dir}/rows" \
		| xargs grep -H -E '^(RssAnon|VmPTE):' > "${memory_guard_dir}/proc" 2>/dev/null
	awk -F '\t' -v OFS='\t' -v min=$(( MEMORY_GUARD_MIN_PRIVATE_MB * 1024 )) -v procfile="${memory_guard_dir}/proc" \
		-v listedfile="${memory_guard_dir}/listed" '
		FILENAME == procfile {
			# <proc>/<pid>/status:<field>: <kB> kB
			i = index($0, "/status:")
			if (i == 0) next
			n = split(substr($0, 1, i - 1), path, "/"); pid = path[n]
			split(substr($0, i + 8), w, /[ \t]+/)
			kb[pid] += w[2]
			next
		}
		$1 !~ /^[0-9]+$/ { next }
		{ listed++ }
		$3 == "parallel worker" { worker[$2] += kb[$1]; next }
		$3 == "client backend" && ($1 in kb) && $5 ~ /^[0-9]+$/ { rows[$1] = $0 }
		END {
			print listed + 0 > listedfile
			for (pid in rows) {
				split(rows[pid], f, "\t")
				total = kb[pid] + worker[pid]
				if (total < min) continue
				print total, pid, f[5], f[4], f[6], f[7], f[8], f[9], f[10]
			}
		}' "${memory_guard_dir}/proc" "${memory_guard_dir}/rows" | sort -t "${MEMORY_TAB}" -k1,1nr > "${memory_guard_dir}/ranking"
	return 0
}

# Decides what to end from <state>/ranking, the stage, the memory to free (kB) to get back under
# MEMORY_GUARD_ACTIVE_PERC, and the guard's recent actions. Prints one action per line:
#   <action> <expected state> <ranking line>
# and writes "<actions> <rate limited> <eligible> <credit kB>" to <state>/decision.
#  - Pending credit: a session terminated in the last 5 s is still exiting; it is not chosen again
#    and its memory counts as already freed.
#  - idle: the MEMORY_GUARD_IDLE_BATCH idle sessions holding the most, within
#    MEMORY_GUARD_IDLE_MAX_PER_MIN terminations a minute (this stage only).
#  - active: the same, uncapped, plus the busy session holding the most: its query is canceled,
#    and it is terminated when it is still the largest MEMORY_GUARD_CANCEL_GRACE seconds later. A
#    session idle in a transaction runs no query to cancel and is terminated at once.
#  - critical, the last stage before the limit: the sessions holding the most, whatever their
#    state, until what they hold covers the memory to free, up to MEMORY_GUARD_CRITICAL_BATCH.
memory_guard_decide() { # stage kB-to-free now-ms
	memory_guard_dir=${MEMORY_GUARD_STATE_DIR}
	: >> "${memory_guard_dir}/pending"
	: >> "${memory_guard_dir}/idle_times"
	: >> "${memory_guard_dir}/ranking"
	memory_guard_cancel_pid='' memory_guard_cancel_start='' memory_guard_cancel_at=''
	if [ -r "${memory_guard_dir}/cancel" ]
	then
		read -r memory_guard_cancel_pid memory_guard_cancel_start memory_guard_cancel_at < "${memory_guard_dir}/cancel" || true
	fi
	memory_guard_allow=-1
	[ "${MEMORY_GUARD_IDLE_MAX_PER_MIN}" -gt 0 ] && memory_guard_allow=${MEMORY_GUARD_IDLE_MAX_PER_MIN}
	awk -F '\t' -v OFS='\t' -v stage="$1" -v need="$2" -v now="$3" \
		-v batch="${MEMORY_GUARD_IDLE_BATCH}" -v allow="${memory_guard_allow}" -v critical_batch="${MEMORY_GUARD_CRITICAL_BATCH}" \
		-v grace=$(( MEMORY_GUARD_CANCEL_GRACE * 1000 )) -v cpid="${memory_guard_cancel_pid}" -v cstart="${memory_guard_cancel_start}" \
		-v cat="${memory_guard_cancel_at:-0}" -v pendingfile="${memory_guard_dir}/pending" -v idlefile="${memory_guard_dir}/idle_times" \
		-v dir="${memory_guard_dir}" '
		function act(action, expect) { actions++; print action, expect, $0 }
		BEGIN { printf "" > (dir "/pending.new"); printf "" > (dir "/idle_times.new") }
		FILENAME == pendingfile {
			if ($4 ~ /^[0-9]+$/ && now - $4 < 5000) { print > (dir "/pending.new"); pending[$1] = $2; pending_kb[$1] = $3 }
			next
		}
		FILENAME == idlefile {
			if ($1 ~ /^[0-9]+$/ && now - $1 < 60000) { print > (dir "/idle_times.new"); recent++ }
			next
		}
		FNR == 1 { pass++ }
		$1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { next }
		pass == 1 { if (($2 in pending) && pending[$2] == $3) credit += pending_kb[$2]; next }
		($2 in pending) && pending[$2] == $3 { next }
		{ eligible++ }
		stage == "critical" {
			if (ended < critical_batch && (freed < need - credit || (ended == 0 && credit == 0))) { ended++; freed += $1; act("terminate", "") }
			next
		}
		$4 == "idle" {
			if (ended < batch) {
				if (stage == "idle" && allow >= 0 && recent + ended >= allow) { limited = 1; next }
				ended++
				act("terminate", "idle")
			}
			next
		}
		stage == "active" && !busy {
			busy = 1
			if ($2 == cpid && $3 == cstart) { if (now - cat >= grace) act("terminate", "") }
			else if ($4 == "active") act("cancel", "")
			else act("terminate", "")
		}
		END { print actions + 0, limited + 0, eligible + 0, credit + 0 > (dir "/decision") }' \
		"${memory_guard_dir}/pending" "${memory_guard_dir}/idle_times" "${memory_guard_dir}/ranking" "${memory_guard_dir}/ranking"
	mv -f "${memory_guard_dir}/pending.new" "${memory_guard_dir}/pending"
	mv -f "${memory_guard_dir}/idle_times.new" "${memory_guard_dir}/idle_times"
}

# Ends the sessions in <state>/actions with one statement, re-checking each against what it was
# listed as: same pid and backend_start (pid reuse), still a client backend, still not a superuser,
# and still idle when it was chosen for being idle. One row per session comes back with its own
# result. In dry-run, or while the pause file exists, nothing is sent.
memory_guard_act() { # result-when-not-enforcing
	memory_guard_dir=${MEMORY_GUARD_STATE_DIR}
	: > "${memory_guard_dir}/results"
	[ -n "$1" ] && return 0
	memory_guard_act_sql=$(awk -F '\t' '
		$4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && ($1 == "cancel" || $1 == "terminate") && ($2 == "" || $2 == "idle") {
			values = values sep "(" $4 ", " $5 ", '\''" $1 "'\'', '\''" $2 "'\'')"; sep = ", "
		}
		END {
			if (values == "") exit
			print "SELECT v.pid, CASE WHEN a.pid IS NULL THEN '\''skipped'\'' WHEN v.action = '\''cancel'\'' THEN pg_cancel_backend(a.pid)::text ELSE pg_terminate_backend(a.pid)::text END"
			print "FROM (VALUES " values ") AS v(pid, backend_start, action, expected_state)"
			print "LEFT JOIN pg_stat_activity a ON a.pid = v.pid"
			print "AND coalesce((extract(epoch FROM a.backend_start) * 1000000)::bigint, 0) = v.backend_start::bigint"
			print "AND a.backend_type = '\''client backend'\''"
			print "AND (v.expected_state = '\'''\'' OR a.state = v.expected_state)"
			print "AND a.usesysid IN (SELECT r.oid FROM pg_roles r WHERE r.rolsuper IS FALSE)"
		}' "${memory_guard_dir}/actions")
	[ -n "${memory_guard_act_sql}" ] || return 0
	memory_guard_psql "${memory_guard_act_sql}" > "${memory_guard_dir}/results" 2>/dev/null || : > "${memory_guard_dir}/results"
	return 0
}

# Prints one WARN line per action and records what was done: terminations as pending credit and,
# in stage idle, against the rate cap; a cancel for its grace. Writes "<terminated> <canceled>" to
# <state>/counts. Dry-run and paused actions are recorded as if done, so the log shows what
# enforce would do.
memory_guard_record() { # result-when-not-enforcing stage pct used-MB limit-MB now-ms
	memory_guard_dir=${MEMORY_GUARD_STATE_DIR}
	memory_guard_cancel_pid='' memory_guard_cancel_start='' memory_guard_cancel_at=''
	if [ -r "${memory_guard_dir}/cancel" ]
	then
		read -r memory_guard_cancel_pid memory_guard_cancel_start memory_guard_cancel_at < "${memory_guard_dir}/cancel" || true
	fi
	awk -F '\t' -v forced="$1" -v stage="$2" -v pct="$3" -v used="$4" -v limit="$5" -v now="$6" \
		-v prefix="$(memory_log_prefix)" -v resultsfile="${memory_guard_dir}/results" -v dir="${memory_guard_dir}" \
		-v cpid="${memory_guard_cancel_pid}" -v cstart="${memory_guard_cancel_start}" -v cat="${memory_guard_cancel_at}" '
		function q(s) { gsub(/"/, "'\''", s); return "\"" s "\"" }
		FILENAME == resultsfile { result[$1] = $2; next }
		$4 !~ /^[0-9]+$/ { next }
		{
			action = $1; expect = $2; kb = $3; pid = $4; start = $5
			if (forced != "") res = forced
			else if (!(pid in result)) res = "failed"
			else if (result[pid] == "true" || result[pid] == "t") res = "ok"
			else if (result[pid] == "false" || result[pid] == "f" || result[pid] == "skipped") res = "skipped"
			else res = "failed"
			line = prefix " WARN: event=action action=" action " stage=" stage " pid=" pid " usename=" q($7) \
				" datname=" q($8) " application_name=" q($9) " state=" q($6) " private_mb=" int(kb / 1024) \
				" used_pct=" pct " used_mb=" used " limit_mb=" limit " result=" res " query_id=" $10 " query=" q($11)
			print substr(line, 1, 4000)
			if (res == "ok" || res == "dry-run" || res == "paused") {
				if (action == "terminate") {
					terminated++
					print pid "\t" start "\t" kb "\t" now >> (dir "/pending")
					if (stage == "idle" && expect == "idle") print now >> (dir "/idle_times")
					if (pid == cpid) cleared = 1
				} else {
					canceled++
					cancel = pid " " start " " now
				}
			}
		}
		END {
			if (cancel != "") print cancel > (dir "/cancel")
			else if (cleared || cpid == "") printf "" > (dir "/cancel")
			else print cpid " " cstart " " cat > (dir "/cancel")
			print terminated + 0, canceled + 0 > (dir "/counts")
		}' "${memory_guard_dir}/results" "${memory_guard_dir}/actions"
}

# Tells whether the postmaster is running, from postmaster.pid: running or not_running.
memory_postmaster() {
	memory_postmaster_pid=
	if [ -r "${PGDATA:-}/postmaster.pid" ]
	then
		read -r memory_postmaster_pid < "${PGDATA}/postmaster.pid" || true
	fi
	case "${memory_postmaster_pid}" in
		''|*[!0-9]*) echo not_running ;;
		*)
			if kill -0 "${memory_postmaster_pid}" 2>/dev/null
			then
				echo running
			else
				echo not_running
			fi
			;;
	esac
}

# The guard's scalar state, kept in a file since every pass runs in a subshell. The first line
# is what the loop reads to know how long to sleep. Written whole and renamed, so it is never
# read half written.
memory_guard_load() {
	mg_sleep_ms='' mg_stage='' mg_oom='' mg_status_at='' mg_status_peak='' mg_status_t='' mg_status_c=''
	mg_episode_at='' mg_episode_peak='' mg_episode_t='' mg_episode_c='' mg_psql_failed_at='' mg_rate_limited_at=''
	mg_slow_at='' mg_no_candidate='' mg_throttle_ms='' mg_scan_at='' mg_scan_scope=''
	if [ -r "${MEMORY_GUARD_STATE_DIR}/state" ]
	then
		# shellcheck disable=SC1091  # written by memory_guard_save
		. "${MEMORY_GUARD_STATE_DIR}/state"
	fi
	mg_stage=${mg_stage:-normal}
	mg_oom=${mg_oom:--1}
	mg_status_at=${mg_status_at:-0}
	mg_status_peak=${mg_status_peak:-0}
	mg_status_t=${mg_status_t:-0}
	mg_status_c=${mg_status_c:-0}
	mg_episode_at=${mg_episode_at:-0}
	mg_episode_peak=${mg_episode_peak:-0}
	mg_episode_t=${mg_episode_t:-0}
	mg_episode_c=${mg_episode_c:-0}
	mg_psql_failed_at=${mg_psql_failed_at:--60000}
	mg_rate_limited_at=${mg_rate_limited_at:--60000}
	mg_slow_at=${mg_slow_at:--60000}
	mg_throttle_ms=${mg_throttle_ms:-0}
	mg_scan_at=${mg_scan_at:-0}
	mg_scan_scope=${mg_scan_scope:-all}
}

memory_guard_save() {
	if [ "${mg_stage}" = normal ]
	then
		mg_sleep_ms=${MEMORY_GUARD_INTERVAL_MS}
	else
		mg_sleep_ms=${MEMORY_GUARD_FAST_INTERVAL_MS}
	fi
	[ "${mg_throttle_ms}" -gt "${mg_sleep_ms}" ] && mg_sleep_ms=${mg_throttle_ms}
	printf 'mg_sleep_ms=%s\nmg_stage=%s\nmg_oom=%s\nmg_status_at=%s\nmg_status_peak=%s\nmg_status_t=%s\nmg_status_c=%s\nmg_episode_at=%s\nmg_episode_peak=%s\nmg_episode_t=%s\nmg_episode_c=%s\nmg_psql_failed_at=%s\nmg_rate_limited_at=%s\nmg_slow_at=%s\nmg_no_candidate=%s\nmg_throttle_ms=%s\nmg_scan_at=%s\nmg_scan_scope=%s\n' \
		"${mg_sleep_ms}" "${mg_stage}" "${mg_oom}" "${mg_status_at}" "${mg_status_peak}" "${mg_status_t}" "${mg_status_c}" \
		"${mg_episode_at}" "${mg_episode_peak}" "${mg_episode_t}" "${mg_episode_c}" "${mg_psql_failed_at}" \
		"${mg_rate_limited_at}" "${mg_slow_at}" "${mg_no_candidate}" "${mg_throttle_ms}" "${mg_scan_at}" "${mg_scan_scope}" \
		> "${MEMORY_GUARD_STATE_DIR}/state.new" && mv -f "${MEMORY_GUARD_STATE_DIR}/state.new" "${MEMORY_GUARD_STATE_DIR}/state"
}

# One pass of the guard: read the cgroup, follow the stage, act under pressure, then measure the
# pass. A full pass longer than MEMORY_GUARD_TICK_BUDGET_MS throttles the guard: the interval
# doubles, and is at least as long as that pass took, up to MEMORY_GUARD_MAX_INTERVAL, and passes act from the last ranking (re-checked by the
# action statement) with a full scan only every MEMORY_GUARD_MAX_INTERVAL, until a full pass is
# back under the budget.
memory_guard_tick() {
	memory_guard_load
	memory_now
	memory_guard_tick_start=${memory_now_ms}
	memory_guard_listed=0
	memory_guard_full=1
	memory_guard_pass
	memory_now
	memory_guard_tick_ms=$(( memory_now_ms - memory_guard_tick_start ))
	if [ "${memory_guard_full}" = 1 ]
	then
		if [ "${memory_guard_tick_ms}" -gt "${MEMORY_GUARD_TICK_BUDGET_MS}" ]
		then
			if [ "${mg_stage}" = normal ]
			then
				memory_guard_base_ms=${MEMORY_GUARD_INTERVAL_MS}
			else
				memory_guard_base_ms=${MEMORY_GUARD_FAST_INTERVAL_MS}
			fi
			[ "${mg_throttle_ms}" -gt "${memory_guard_base_ms}" ] && memory_guard_base_ms=${mg_throttle_ms}
			mg_throttle_ms=$(( memory_guard_base_ms * 2 ))
			# At least as long as the slow pass took, so the guard spends at most half its time in passes.
			[ "${memory_guard_tick_ms}" -gt "${mg_throttle_ms}" ] && mg_throttle_ms=${memory_guard_tick_ms}
			[ "${mg_throttle_ms}" -gt "${MEMORY_GUARD_MAX_INTERVAL_MS}" ] && mg_throttle_ms=${MEMORY_GUARD_MAX_INTERVAL_MS}
			if [ $(( memory_now_ms - mg_slow_at )) -ge 60000 ]
			then
				memory_log WARN slow_tick "tick_ms=${memory_guard_tick_ms}" "sessions=${memory_guard_listed}" \
					"budget_ms=${MEMORY_GUARD_TICK_BUDGET_MS}" "interval_ms=${mg_throttle_ms}"
				mg_slow_at=${memory_now_ms}
			fi
		else
			mg_throttle_ms=0
		fi
	fi
	memory_guard_save
	return 0
}

memory_guard_pass() {
	memory_guard_reading=$(memory_read) || memory_guard_reading=
	case "${memory_guard_reading}" in
		''|unlimited) return 0 ;;
	esac
	# shellcheck disable=SC2086  # six numbers
	set -- ${memory_guard_reading}
	pct=$1 used_mb=$2 limit_mb=$3 oom=$4 used_kb=$5 limit_kb=$6
	now=${memory_now_ms}

	# Kills by the kernel since the last pass.
	if [ "${oom}" -ge 0 ]
	then
		if [ "${mg_oom}" -ge 0 ] && [ "${oom}" -gt "${mg_oom}" ]
		then
			memory_log ERROR oom_kill "killed=$(( oom - mg_oom ))" "from=${mg_oom}" "to=${oom}" "used_pct=${pct}" \
				"limit_mb=${limit_mb}" "postmaster=$(memory_postmaster)" 'note="crash recovery: every session ended"'
		fi
		mg_oom=${oom}
	fi

	# Stage.
	stage=normal
	[ "${pct}" -ge "${MEMORY_GUARD_IDLE_PERC}" ] && stage=idle
	[ "${pct}" -ge "${MEMORY_GUARD_ACTIVE_PERC}" ] && stage=active
	[ "${pct}" -ge "${MEMORY_GUARD_CRITICAL_PERC}" ] && stage=critical
	if [ "${stage}" != "${mg_stage}" ]
	then
		if [ "${stage}" = normal ]
		then
			memory_log LOG stage "from=${mg_stage}" "to=${stage}" "used_pct=${pct}" "used_mb=${used_mb}" "limit_mb=${limit_mb}"
			if [ $(( mg_episode_t + mg_episode_c )) -gt 0 ]
			then
				memory_log LOG relief "duration_s=$(( (now - mg_episode_at) / 1000 ))" "peak_pct=${mg_episode_peak}" \
					"terminated=${mg_episode_t}" "canceled=${mg_episode_c}"
			fi
		else
			memory_log WARN stage "from=${mg_stage}" "to=${stage}" "used_pct=${pct}" "used_mb=${used_mb}" "limit_mb=${limit_mb}"
			if [ "${mg_stage}" = normal ]
			then
				mg_episode_at=${now} mg_episode_peak=${pct} mg_episode_t=0 mg_episode_c=0
			fi
			# A new stage needs a fresh ranking.
			mg_scan_at=0
		fi
		mg_stage=${stage}
		mg_no_candidate=
	fi
	[ "${pct}" -gt "${mg_status_peak}" ] && mg_status_peak=${pct}
	[ "${stage}" != normal ] && [ "${pct}" -gt "${mg_episode_peak}" ] && mg_episode_peak=${pct}

	# Periodic status.
	if [ "${MEMORY_GUARD_STATUS_INTERVAL}" -gt 0 ] && [ $(( now - mg_status_at )) -ge $(( MEMORY_GUARD_STATUS_INTERVAL * 1000 )) ]
	then
		memory_log LOG status "used_pct=${pct}" "peak_pct=${mg_status_peak}" "used_mb=${used_mb}" "limit_mb=${limit_mb}" \
			"terminated=${mg_status_t}" "canceled=${mg_status_c}"
		mg_status_at=${now} mg_status_peak=${pct} mg_status_t=0 mg_status_c=0
	fi

	# Nothing to do below the first threshold: no psql, no /proc.
	if [ "${stage}" = normal ]
	then
		rm -f "${MEMORY_GUARD_STATE_DIR}/cancel" "${MEMORY_GUARD_STATE_DIR}/ranking"
		return 0
	fi

	# Full scan, or the last ranking while throttled, when it covers this stage. Stage idle only
	# ends idle sessions, so its listing (and the /proc reads after it) takes those alone.
	memory_guard_scope=all
	[ "${stage}" = idle ] && memory_guard_scope=idle
	if [ "${mg_throttle_ms}" -gt 0 ] && [ "${mg_scan_at}" -gt 0 ] && [ -r "${MEMORY_GUARD_STATE_DIR}/ranking" ] \
		&& [ $(( now - mg_scan_at )) -lt "${MEMORY_GUARD_MAX_INTERVAL_MS}" ] \
		&& { [ "${mg_scan_scope}" = all ] || [ "${memory_guard_scope}" = idle ]; }
	then
		memory_guard_full=0
	elif memory_guard_scan "${memory_guard_scope}"
	then
		mg_scan_at=${now}
		mg_scan_scope=${memory_guard_scope}
		read -r memory_guard_listed < "${MEMORY_GUARD_STATE_DIR}/listed" || memory_guard_listed=0
	else
		# Throttled: while the server is down or starting, every pass would fail the same way.
		if [ $(( now - mg_psql_failed_at )) -ge 60000 ]
		then
			memory_guard_error=
			read -r memory_guard_error < "${MEMORY_GUARD_STATE_DIR}/psql.err" || true
			memory_log WARN psql_failed "used_pct=${pct}" "error=$(memory_quote "${memory_guard_error:-psql failed}")"
			mg_psql_failed_at=${now}
		fi
		return 0
	fi

	memory_guard_decide "${stage}" $(( used_kb - limit_kb * MEMORY_GUARD_ACTIVE_PERC / 100 )) "${now}" > "${MEMORY_GUARD_STATE_DIR}/actions"
	read -r memory_guard_actions memory_guard_limited memory_guard_eligible memory_guard_credit < "${MEMORY_GUARD_STATE_DIR}/decision" || return 0
	if [ "${memory_guard_limited}" = 1 ] && [ $(( now - mg_rate_limited_at )) -ge 60000 ]
	then
		memory_log WARN rate_limited stage=idle "max_per_min=${MEMORY_GUARD_IDLE_MAX_PER_MIN}"
		mg_rate_limited_at=${now}
	fi
	if [ "${memory_guard_actions}" = 0 ]
	then
		if [ "${memory_guard_eligible}" = 0 ] && [ "${memory_guard_credit}" = 0 ] && [ "${mg_no_candidate}" != "${stage}" ]
		then
			memory_log WARN no_candidate "stage=${stage}" "used_pct=${pct}" "min_private_mb=${MEMORY_GUARD_MIN_PRIVATE_MB}"
			mg_no_candidate=${stage}
		fi
		return 0
	fi
	mg_no_candidate=
	if memory_guard_paused
	then
		memory_guard_forced=paused
	elif [ "${MEMORY_GUARD_MODE}" = dry-run ]
	then
		memory_guard_forced=dry-run
	else
		memory_guard_forced=
	fi
	memory_guard_act "${memory_guard_forced}"
	memory_guard_record "${memory_guard_forced}" "${stage}" "${pct}" "${used_mb}" "${limit_mb}" "${now}" >&2
	memory_guard_t=0 memory_guard_c=0
	read -r memory_guard_t memory_guard_c < "${MEMORY_GUARD_STATE_DIR}/counts" || true
	mg_status_t=$(( mg_status_t + ${memory_guard_t:-0} )) mg_status_c=$(( mg_status_c + ${memory_guard_c:-0} ))
	mg_episode_t=$(( mg_episode_t + ${memory_guard_t:-0} )) mg_episode_c=$(( mg_episode_c + ${memory_guard_c:-0} ))
	return 0
}

# Sets up the state folder (MEMORY_GUARD_STATE_DIR, a new private one unless set) from the first
# reading. Returns 1 when no folder can be made.
memory_guard_init() { # oom-kills
	if [ -z "${MEMORY_GUARD_STATE_DIR:-}" ]
	then
		# In memory when /dev/shm is there (a few small files), so no pass waits on the disk.
		if [ -d /dev/shm ] && [ -w /dev/shm ]
		then
			MEMORY_GUARD_STATE_DIR=$(mktemp -d /dev/shm/memory_guard.XXXXXX 2>/dev/null) || MEMORY_GUARD_STATE_DIR=
		fi
		[ -n "${MEMORY_GUARD_STATE_DIR:-}" ] || MEMORY_GUARD_STATE_DIR=$(mktemp -d 2>/dev/null) || return 1
		[ -n "${MEMORY_GUARD_STATE_DIR}" ] || return 1
	fi
	memory_guard_load
	memory_now
	mg_oom=$1
	mg_status_at=${memory_now_ms}
	memory_guard_save
}

# Lowers the guard's own CPU and IO priority, so the server always comes first. Best effort; the
# result goes into the start line. Children (psql, awk, grep) inherit both.
memory_guard_priority() {
	memory_guard_nice=unavailable
	memory_guard_ionice=unavailable
	if command -v renice > /dev/null 2>&1 && renice -n 10 -p $$ > /dev/null 2>&1
	then
		memory_guard_nice=10
	fi
	# The best-effort class at its lowest level, not the idle class: a busy database does I/O all
	# the time, and the idle class would then starve the guard's own reads and process starts.
	if command -v ionice > /dev/null 2>&1 && ionice -c 2 -n 7 -p $$ > /dev/null 2>&1
	then
		memory_guard_ionice=best-effort-7
	fi
}

# The guard's loop. Every pass runs in a subshell, so nothing a pass hits (an odd reading, a psql
# failure) can end the loop. The process only ever exits with 0: once the init script execs into
# the postmaster the guard is its child, and the postmaster may treat a child that exits
# otherwise, or is killed by a signal, as a crashed server process and restart every session. Stop
# it with TERM (or pause it with the pause file), never with KILL.
memory_guard_main() {
	trap 'exit 0' TERM INT HUP
	memory_guard_settings
	if [ "${MEMORY_GUARD_ENABLED}" != "true" ]
	then
		memory_log LOG disabled reason=off
		exit 0
	fi
	# The cgroup may not be readable at the very start; give it 30 s.
	memory_guard_tries=0
	while :
	do
		memory_cgroup
		memory_guard_reading=$(memory_read) || memory_guard_reading=
		[ -n "${memory_guard_reading}" ] && break
		[ "${memory_guard_tries}" -ge "${MEMORY_GUARD_CGROUP_RETRY:-30}" ] && break
		memory_guard_tries=$(( memory_guard_tries + 1 ))
		sleep 1 || true
	done
	case "${memory_guard_reading}" in
		unlimited)
			memory_log LOG disabled reason=unlimited
			exit 0
			;;
		'')
			memory_log LOG disabled reason=no_cgroup
			exit 0
			;;
	esac
	# shellcheck disable=SC2086  # six numbers
	set -- ${memory_guard_reading}
	if ! memory_guard_init "$4"
	then
		memory_log LOG disabled reason=no_state_dir
		exit 0
	fi
	memory_guard_priority
	memory_log LOG start "mode=${MEMORY_GUARD_MODE}" "cgroup=${MEMORY_CGROUP}" "limit_mb=$3" "used_pct=$1" "used_mb=$2" \
		"interval=${MEMORY_GUARD_INTERVAL}" "fast_interval=${MEMORY_GUARD_FAST_INTERVAL}" \
		"max_interval=${MEMORY_GUARD_MAX_INTERVAL}" "tick_budget_ms=${MEMORY_GUARD_TICK_BUDGET_MS}" "idle_perc=${MEMORY_GUARD_IDLE_PERC}" \
		"active_perc=${MEMORY_GUARD_ACTIVE_PERC}" "critical_perc=${MEMORY_GUARD_CRITICAL_PERC}" \
		"min_private_mb=${MEMORY_GUARD_MIN_PRIVATE_MB}" "oom_kills=$4" "nice=${memory_guard_nice}" "ionice=${memory_guard_ionice}"
	while :
	do
		( memory_guard_tick ) || true
		memory_guard_sleep_line=
		if [ -r "${MEMORY_GUARD_STATE_DIR}/state" ]
		then
			read -r memory_guard_sleep_line < "${MEMORY_GUARD_STATE_DIR}/state" || true
		fi
		memory_guard_sleep_ms=${memory_guard_sleep_line#mg_sleep_ms=}
		case "${memory_guard_sleep_ms}" in
			''|*[!0-9]*) memory_guard_sleep_ms=${MEMORY_GUARD_INTERVAL_MS} ;;
		esac
		memory_sleep "${memory_guard_sleep_ms}"
	done
}
