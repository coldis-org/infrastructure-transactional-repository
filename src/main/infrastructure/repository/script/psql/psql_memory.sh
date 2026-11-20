#!/bin/sh

# Out-of-memory handling of the server, sourced by the init scripts and by psql_memory_guard.sh.
# Defines functions only.
#
# Inside a container the kernel kills a process once the container's memory limit is reached.
# Whatever it kills, the database pays dearly: a server process killed by a signal makes the
# postmaster end every other session and run crash recovery, refusing connections meanwhile, and
# thousands of clients then reconnect at once, which can bring the next kill. Two things here:
#
#  - The memory guard (memory_guard_main, run by psql_memory_guard.sh), the protection that
#    counts: before the limit is reached it ends the sessions holding the most private memory,
#    idle ones first, so the kernel does not have to kill anything. Ending a session this way
#    costs that session only.
#  - OOM targeting (psql_oom_target): every process the postmaster starts raises its own
#    oom_score_adj (PostgreSQL writes PG_OOM_ADJUST_VALUE to PG_OOM_ADJUST_FILE after fork), so
#    when the kernel does kill, the victim is a backend and never the postmaster, whose death
#    would take the container down. It only makes that choice deterministic: any kill still
#    means crash recovery. It cannot help when the runtime sets memory.oom.group=1 on the
#    container's cgroup: then the kernel kills every process in it together.
#
# Every line logged here starts with MEMORY_GUARD: (after the date), in English whatever the
# server's locale, so it can be found with one grep.
#
# Memory is read from the container's cgroup: v2 memory.current, memory.max, memory.stat and
# memory.events, or v1 memory.usage_in_bytes, memory.limit_in_bytes, memory.stat and
# memory.oom_control. The file page cache (active_file and inactive_file) is left out of the use:
# the kernel reclaims it before killing anything, and a database keeps it full.

# Tab, the field separator of every list below.
MEMORY_TAB=$(printf '\t')

# Logs one line to stderr, as the server does: date, the MEMORY_GUARD: tag, the level, the message.
memory_log() { # level message...
	memory_log_level=$1
	shift
	echo "$(date '+%Y-%m-%d %H:%M:%S %Z') MEMORY_GUARD: ${memory_log_level}: $*" >&2
}

# Prints the integer setting value $2 (named $1 in warnings): $3 when empty, $3 with a warning
# when not an integer, clamped to $4..$5 with a warning. Keeps every later arithmetic expansion
# valid whatever the environment holds.
memory_setting() { # name value default min max
	memory_setting_value=${2:-$3}
	case "${memory_setting_value#-}" in
		''|*[!0-9]*)
			memory_log WARN "$1=$2 is not an integer; using $3."
			memory_setting_value=$3
			;;
	esac
	if [ "${memory_setting_value}" -lt "$4" ] || [ "${memory_setting_value}" -gt "$5" ]
	then
		memory_log WARN "$1=${memory_setting_value} is not between $4 and $5; clamping it."
		memory_setting_value=$(( memory_setting_value < $4 ? $4 : $5 ))
	fi
	echo "${memory_setting_value}"
}

# Prints the duration in seconds $2 (named $1 in warnings), a positive number with at most one
# decimal point, or $3 with a warning.
memory_seconds() { # name value default
	case "$2" in
		*[!0-9.]*|*.*.*) memory_log WARN "$1=$2 is not a positive number of seconds; using $3."; echo "$3" ;;
		*[1-9]*) echo "$2" ;;
		*) memory_log WARN "$1=$2 is not a positive number of seconds; using $3."; echo "$3" ;;
	esac
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

# Reads the cgroup once. Prints "<used %> <used MB> <limit MB> <oom kills>", or "unlimited" when
# the cgroup has no limit (v2 "max", v1 a page-rounded 2^63), or nothing when it cannot be read.
# The oom kill count is -1 when the kernel does not report it.
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
		FILENAME ~ /(memory\.max|memory\.limit_in_bytes)$/ { limit = $1 }
		FILENAME ~ /(memory\.current|memory\.usage_in_bytes)$/ { current = $1 }
		FILENAME ~ /memory\.stat$/ && ($1 == "active_file" || $1 == "inactive_file" || $1 == "total_active_file" || $1 == "total_inactive_file") { file += $2 }
		FILENAME ~ /(memory\.events|memory\.oom_control)$/ && $1 == "oom_kill" { oom = $2 }
		END {
			if (limit == "" || current == "") exit 1
			if (limit == "max" || limit + 0 >= 1152921504606846976) { print "unlimited"; exit 0 }
			if (limit + 0 <= 0) exit 1
			used = current - file
			if (used < 0) used = 0
			printf "%d %.0f %.0f %.0f\n", used * 100 / limit, used / 1048576, limit / 1048576, oom
		}' "$@" 2>/dev/null
}

# Reads a cgroup file, or "unknown".
memory_cgroup_value() { # file
	if [ -r "$1" ]
	then
		head -n 1 "$1"
	else
		echo unknown
	fi
}

# Sets up the OOM targeting for the server about to start, and logs it. Exports
# PG_OOM_ADJUST_FILE and PG_OOM_ADJUST_VALUE, which every process the postmaster forks applies to
# itself. Raising oom_score_adj needs no privilege; lowering it below the inherited value does
# (CAP_SYS_RESOURCE), which is why the postmaster keeps what it inherits and its children go up.
psql_oom_target() {
	OOM_TARGETING_ENABLED=${OOM_TARGETING_ENABLED:-true}
	OOM_CHILD_SCORE_ADJ=$(memory_setting OOM_CHILD_SCORE_ADJ "${OOM_CHILD_SCORE_ADJ}" 900 -1000 1000)
	memory_cgroup
	# /proc/self is the reading process, which inherits the score of this shell, the future
	# postmaster (the init script execs into it).
	OOM_POSTMASTER_SCORE_ADJ=$(cat /proc/self/oom_score_adj 2>/dev/null || echo unknown)
	OOM_MEMORY_MAX=unknown
	OOM_GROUP=unknown
	case "${MEMORY_CGROUP}" in
		v2)
			OOM_MEMORY_MAX=$(memory_cgroup_value "${MEMORY_CGROUP_PATH}/memory.max")
			OOM_GROUP=$(memory_cgroup_value "${MEMORY_CGROUP_PATH}/memory.oom.group")
			;;
		v1)
			OOM_MEMORY_MAX=$(memory_cgroup_value "${MEMORY_CGROUP_PATH}/memory.limit_in_bytes")
			# cgroup v1 has no group kill.
			OOM_GROUP=0
			;;
	esac
	if [ "${OOM_TARGETING_ENABLED}" = "true" ]
	then
		export PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj
		export PG_OOM_ADJUST_VALUE="${OOM_CHILD_SCORE_ADJ}"
		memory_log LOG "OOM targeting on: postmaster oom_score_adj=${OOM_POSTMASTER_SCORE_ADJ}, server processes oom_score_adj=${OOM_CHILD_SCORE_ADJ} (PG_OOM_ADJUST_VALUE), cgroup ${MEMORY_CGROUP} memory.max=${OOM_MEMORY_MAX}, memory.oom.group=${OOM_GROUP}. On out of memory the kernel kills a server process, not the postmaster, so the container survives; any such kill still makes PostgreSQL end every session and run crash recovery, which the memory guard exists to avoid."
		case "${OOM_POSTMASTER_SCORE_ADJ}" in
			''|unknown|*[!0-9-]*) ;;
			*)
				if [ "${OOM_CHILD_SCORE_ADJ}" -le "${OOM_POSTMASTER_SCORE_ADJ}" ]
				then
					memory_log WARN "OOM_CHILD_SCORE_ADJ=${OOM_CHILD_SCORE_ADJ} is not above the postmaster's ${OOM_POSTMASTER_SCORE_ADJ}: server processes cannot go below what they inherit without CAP_SYS_RESOURCE, so they keep ${OOM_POSTMASTER_SCORE_ADJ} and the postmaster is as likely to be killed as they are."
				fi
				;;
		esac
	else
		unset PG_OOM_ADJUST_FILE PG_OOM_ADJUST_VALUE
		memory_log LOG "OOM targeting off (OOM_TARGETING_ENABLED=${OOM_TARGETING_ENABLED}): postmaster and server processes oom_score_adj=${OOM_POSTMASTER_SCORE_ADJ}, cgroup ${MEMORY_CGROUP} memory.max=${OOM_MEMORY_MAX}, memory.oom.group=${OOM_GROUP}. On out of memory the kernel is likely to kill the postmaster, taking the server down."
	fi
	if [ "${OOM_GROUP}" = "1" ]
	then
		memory_log WARN "memory.oom.group=1 on this container's cgroup: on out of memory the kernel kills every process in it together, whatever their oom_score_adj, so OOM targeting cannot protect the postmaster in this runtime. The memory guard is what keeps the limit from being reached here (on Kubernetes, see the kubelet's singleProcessOOMKill)."
	fi
	if [ "${MEMORY_CGROUP}" = none ]
	then
		memory_log LOG "No memory cgroup found under ${MEMORY_CGROUP_DIR}: the container's limit is unknown here."
	fi
	return 0
}

# The guard's settings, read and checked once.
memory_guard_settings() {
	MEMORY_GUARD_ENABLED=${MEMORY_GUARD_ENABLED:-true}
	MEMORY_GUARD_INTERVAL=$(memory_seconds MEMORY_GUARD_INTERVAL "${MEMORY_GUARD_INTERVAL:-2}" 2)
	MEMORY_GUARD_FAST_INTERVAL=$(memory_seconds MEMORY_GUARD_FAST_INTERVAL "${MEMORY_GUARD_FAST_INTERVAL:-0.5}" 0.5)
	MEMORY_GUARD_IDLE_PERC=$(memory_setting MEMORY_GUARD_IDLE_PERC "${MEMORY_GUARD_IDLE_PERC}" 85 1 100)
	MEMORY_GUARD_ACTIVE_PERC=$(memory_setting MEMORY_GUARD_ACTIVE_PERC "${MEMORY_GUARD_ACTIVE_PERC}" 92 1 100)
	MEMORY_GUARD_CRITICAL_PERC=$(memory_setting MEMORY_GUARD_CRITICAL_PERC "${MEMORY_GUARD_CRITICAL_PERC}" 96 1 100)
	MEMORY_GUARD_CRITICAL_BATCH=$(memory_setting MEMORY_GUARD_CRITICAL_BATCH "${MEMORY_GUARD_CRITICAL_BATCH}" 10 1 1000)
	if [ "${MEMORY_GUARD_IDLE_PERC}" -gt "${MEMORY_GUARD_ACTIVE_PERC}" ] || [ "${MEMORY_GUARD_ACTIVE_PERC}" -gt "${MEMORY_GUARD_CRITICAL_PERC}" ]
	then
		memory_log WARN "MEMORY_GUARD_IDLE_PERC=${MEMORY_GUARD_IDLE_PERC}, MEMORY_GUARD_ACTIVE_PERC=${MEMORY_GUARD_ACTIVE_PERC} and MEMORY_GUARD_CRITICAL_PERC=${MEMORY_GUARD_CRITICAL_PERC} are not in increasing order; a later stage then starts before an earlier one."
	fi
	MEMORY_GUARD_IDLE_BATCH=$(memory_setting MEMORY_GUARD_IDLE_BATCH "${MEMORY_GUARD_IDLE_BATCH}" 5 1 1000)
	MEMORY_GUARD_MIN_PRIVATE_MB=$(memory_setting MEMORY_GUARD_MIN_PRIVATE_MB "${MEMORY_GUARD_MIN_PRIVATE_MB}" 8 0 1048576)
	MEMORY_GUARD_QUERY_CHARS=$(memory_setting MEMORY_GUARD_QUERY_CHARS "${MEMORY_GUARD_QUERY_CHARS}" 120 0 1000)
	MEMORY_PROC_DIR=${MEMORY_PROC_DIR:-/proc}
}

# Runs one statement as the admin user over the local socket, one row per line, fields split by
# tabs. Bounded in time so a stuck server cannot stop the guard; never prompts for a password.
memory_guard_psql() { # sql
	PGAPPNAME=psql_memory_guard PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=1000' \
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD:-postgres} PGCONNECT_TIMEOUT=3 \
		timeout 10 psql -X -q -w -A -t -F "${MEMORY_TAB}" -v ON_ERROR_STOP=1 \
		-U "${POSTGRES_ADMIN_USER:-postgres}" -d postgres -c "$1"
}

# Lists the sessions the guard may end, one per line:
#   <private kB> <pid> <state> <user> <database> <application> <query>
# Client backends only: no background process, no WAL sender, no superuser session, not the
# guard's own. A parallel worker's memory is added to the session that leads it. Private memory
# is RssAnon + VmPTE from /proc/<pid>/status: the backend's own heap (work_mem, caches) and its page
# tables, leaving out the shared buffers it maps. status is a counter read, unlike smaps_rollup,
# which walks every mapping and would cost seconds over thousands of backends.
memory_guard_sessions() {
	memory_guard_rows=$(memory_guard_psql "SELECT a.pid, coalesce(a.leader_pid, a.pid), a.backend_type, coalesce(a.state, ''),
			regexp_replace(coalesce(a.usename::text, ''), '[[:space:][:cntrl:]]+', ' ', 'g'),
			regexp_replace(coalesce(a.datname::text, ''), '[[:space:][:cntrl:]]+', ' ', 'g'),
			regexp_replace(coalesce(a.application_name, ''), '[[:space:][:cntrl:]]+', ' ', 'g'),
			regexp_replace(left(coalesce(a.query, ''), ${MEMORY_GUARD_QUERY_CHARS}), '[[:space:][:cntrl:]]+', ' ', 'g')
		FROM pg_stat_activity a LEFT JOIN pg_roles r ON r.oid = a.usesysid
		WHERE a.pid <> pg_backend_pid()
			AND ((a.backend_type = 'client backend' AND r.rolsuper IS FALSE) OR a.backend_type = 'parallel worker')") || return 1
	[ -n "${memory_guard_rows}" ] || return 0
	memory_guard_status=$(echo "${memory_guard_rows}" | awk -F '\t' -v proc="${MEMORY_PROC_DIR}" '$1 ~ /^[0-9]+$/ { print proc "/" $1 "/status" }' \
		| xargs grep -H -E '^(RssAnon|VmPTE):' 2>/dev/null)
	printf '%s\n--\n%s\n' "${memory_guard_status}" "${memory_guard_rows}" | awk -v OFS='\t' -v min=$(( MEMORY_GUARD_MIN_PRIVATE_MB * 1024 )) '
		section == 0 && $0 == "--" { section = 1; FS = "\t"; next }
		section == 0 {
			# <proc>/<pid>/status:<field>: <kB> kB
			n = split($1, path, "/"); pid = path[n - 1]
			kb[pid] += $2
			next
		}
		$1 ~ /^[0-9]+$/ {
			if ($3 == "parallel worker") { worker[$2] += kb[$1]; next }
			if (!($1 in kb)) next
			rows[$1] = $0
		}
		END {
			for (pid in rows) {
				split(rows[pid], f, "\t")
				total = kb[pid] + worker[pid]
				if (total < min) continue
				print total, pid, f[4], f[5], f[6], f[7], f[8]
			}
		}'
}

# Decides what to end, from the sessions on stdin (as memory_guard_sessions lists them), the
# memory use in %, the pid canceled in the previous pass and the memory to free (kB) to get back
# under MEMORY_GUARD_ACTIVE_PERC. Prints one action per line, the session after it:
#   terminate|cancel <private kB> <pid> <state> <user> <database> <application> <query>
# At MEMORY_GUARD_IDLE_PERC: terminate the MEMORY_GUARD_IDLE_BATCH idle sessions holding the most.
# At MEMORY_GUARD_ACTIVE_PERC: also the busy session holding the most, canceling its query first
# and terminating it when it is still the largest on the next pass. A session idle in a
# transaction runs no query to cancel, so it is terminated at once.
# At MEMORY_GUARD_CRITICAL_PERC, the last stage before the limit: terminate the sessions holding
# the most, whatever their state, until what they hold covers the memory to free, up to
# MEMORY_GUARD_CRITICAL_BATCH of them.
# Only ever cancel (SIGINT) or terminate (SIGTERM): a backend leaving that way exits cleanly, where
# one killed by the kernel makes PostgreSQL end every session and run crash recovery.
memory_guard_decide() { # used% canceled-pid kB-to-free
	sort -t "${MEMORY_TAB}" -k1,1nr | awk -F '\t' -v OFS='\t' -v pct="$1" -v canceled="$2" -v need="$3" \
		-v idle="${MEMORY_GUARD_IDLE_PERC}" -v active="${MEMORY_GUARD_ACTIVE_PERC}" -v batch="${MEMORY_GUARD_IDLE_BATCH}" \
		-v critical="${MEMORY_GUARD_CRITICAL_PERC}" -v critical_batch="${MEMORY_GUARD_CRITICAL_BATCH}" '
		$1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { next }
		pct >= critical {
			if (critical_ended < critical_batch && (critical_ended == 0 || freed < need)) { critical_ended++; freed += $1; print "terminate", $0 }
			next
		}
		pct >= idle && $3 == "idle" { if (ended < batch) { ended++; print "terminate", $0 }; next }
		pct >= active && $3 != "idle" && !busy {
			busy = 1
			if ($3 == "active" && $2 != canceled) print "cancel", $0
			else print "terminate", $0
		}'
}

# Ends the sessions memory_guard_decide chose, logging each as one WARN line. Prints the pid it
# canceled, if any, for the next pass. A session is only ended if it is still what it was listed
# as (an idle one only while still idle).
memory_guard_act() { # used% used-MB limit-MB < actions
	while IFS="${MEMORY_TAB}" read -r action kb pid state user database application query
	do
		case "${pid}" in ''|*[!0-9]*) continue ;; esac
		condition="pid = ${pid} AND backend_type = 'client backend'"
		[ "${state}" = idle ] && condition="${condition} AND state = 'idle'"
		if [ "${action}" = cancel ]
		then
			function=pg_cancel_backend
			doing="canceling the query of"
		else
			function=pg_terminate_backend
			doing="terminating"
		fi
		result=$(memory_guard_psql "SELECT ${function}(pid) FROM pg_stat_activity WHERE ${condition}" 2>&1)
		case "${result}" in
			t) result=ok ;;
			f|'') result="skipped (gone or changed)" ;;
			*) result="failed: $(echo "${result}" | tr '\n' ' ')" ;;
		esac
		memory_log WARN "memory at $1% of $3 MB (${2} MB in use; idle threshold ${MEMORY_GUARD_IDLE_PERC}%, active ${MEMORY_GUARD_ACTIVE_PERC}%): ${doing} pid=${pid} usename=${user} datname=${database} application_name=\"$(echo "${application}" | tr '"' "'")\" state=\"${state}\" private_mb=$(( kb / 1024 )) query=\"$(echo "${query}" | tr '"' "'")\" result=${result}"
		[ "${action}" = cancel ] && [ "${result}" = ok ] && echo "${pid}"
	done
	return 0
}

# Reads or writes a value of the guard's state, kept in files since every pass runs in a subshell.
memory_guard_state() { # name [value]
	if [ $# -gt 1 ]
	then
		echo "$2" > "${MEMORY_GUARD_STATE_DIR}/$1"
	else
		cat "${MEMORY_GUARD_STATE_DIR}/$1" 2>/dev/null
	fi
}

# Tells whether the postmaster is running, from postmaster.pid.
memory_postmaster() {
	memory_postmaster_pid=$(head -n 1 "${PGDATA}/postmaster.pid" 2>/dev/null)
	case "${memory_postmaster_pid}" in
		''|*[!0-9]*) echo "postmaster not found (${PGDATA}/postmaster.pid)" ;;
		*)
			if kill -0 "${memory_postmaster_pid}" 2>/dev/null
			then
				echo "postmaster pid ${memory_postmaster_pid} still running"
			else
				echo "postmaster pid ${memory_postmaster_pid} NOT running"
			fi
			;;
	esac
}

# One pass of the guard.
memory_guard_tick() {
	memory_guard_reading=$(memory_read) || memory_guard_reading=
	[ -n "${memory_guard_reading}" ] && [ "${memory_guard_reading}" != unlimited ] || return 0
	# shellcheck disable=SC2086  # four numbers
	set -- ${memory_guard_reading}
	pct=$1 used=$2 limit=$3 oom=$4

	# Kills by the kernel since the last pass.
	oom_last=$(memory_guard_state oom_kill)
	if [ "${oom}" -ge 0 ] && [ -n "${oom_last}" ] && [ "${oom}" -gt "${oom_last}" ]
	then
		memory_log ERROR "OOM kill: crash recovery. The kernel OOM killer killed $(( oom - oom_last )) process(es) in this container (memory.events oom_kill ${oom_last} -> ${oom}; memory now ${pct}% of ${limit} MB, ${used} MB in use; $(memory_postmaster)). A server process killed by a signal makes PostgreSQL end every session and run crash recovery, refusing connections until it finishes; its own log names the process (\"terminated by signal 9\" / \"terminado pelo sinal 9\")."
	fi
	[ "${oom}" -ge 0 ] && memory_guard_state oom_kill "${oom}"

	# Pressure.
	level=normal
	[ "${pct}" -ge "${MEMORY_GUARD_IDLE_PERC}" ] && level=idle
	[ "${pct}" -ge "${MEMORY_GUARD_ACTIVE_PERC}" ] && level=active
	[ "${pct}" -ge "${MEMORY_GUARD_CRITICAL_PERC}" ] && level=critical
	level_last=$(memory_guard_state level)
	if [ "${level}" != "${level_last:-normal}" ]
	then
		case "${level}" in
			normal) memory_log LOG "memory back to ${pct}% of ${limit} MB (${used} MB in use), below ${MEMORY_GUARD_IDLE_PERC}%." ;;
			idle) memory_log WARN "memory at ${pct}% of ${limit} MB (${used} MB in use), at or above ${MEMORY_GUARD_IDLE_PERC}%: ending the idle sessions holding the most memory." ;;
			active) memory_log WARN "memory at ${pct}% of ${limit} MB (${used} MB in use), at or above ${MEMORY_GUARD_ACTIVE_PERC}%: also canceling, then terminating, the busy session holding the most memory." ;;
			critical) memory_log WARN "memory at ${pct}% of ${limit} MB (${used} MB in use), at or above ${MEMORY_GUARD_CRITICAL_PERC}%: terminating the sessions holding the most memory, busy or idle, until back under ${MEMORY_GUARD_ACTIVE_PERC}%." ;;
		esac
		memory_guard_state level "${level}"
	fi
	if [ "${level}" = normal ]
	then
		memory_guard_state canceled ""
		return 0
	fi

	if ! sessions=$(memory_guard_sessions)
	then
		# Throttled: while the server is down or starting, every pass would fail the same way.
		now=$(date +%s)
		failed_last=$(memory_guard_state psql_failed)
		if [ $(( now - ${failed_last:-0} )) -ge 60 ]
		then
			memory_log WARN "memory at ${pct}% of ${limit} MB but the sessions could not be listed (server not accepting connections?); retrying on every pass."
			memory_guard_state psql_failed "${now}"
		fi
		return 0
	fi
	need=$(( (used - limit * MEMORY_GUARD_ACTIVE_PERC / 100) * 1024 ))
	actions=$(echo "${sessions}" | memory_guard_decide "${pct}" "$(memory_guard_state canceled)" "${need}")
	if [ -z "${actions}" ]
	then
		if [ "$(memory_guard_state none_logged)" != "${level}" ]
		then
			memory_log WARN "memory at ${pct}% of ${limit} MB but no session the guard may end holds ${MEMORY_GUARD_MIN_PRIVATE_MB} MB or more (superuser, replication and background processes are never ended)."
			memory_guard_state none_logged "${level}"
		fi
		return 0
	fi
	memory_guard_state none_logged ""
	memory_guard_state canceled "$(echo "${actions}" | memory_guard_act "${pct}" "${used}" "${limit}")"
}

# The guard's loop. Every pass runs in a subshell, so nothing a pass hits (an arithmetic error on
# an odd reading, a psql failure) can end the loop. The process only ever exits with 0: it is a
# child of the postmaster once the init script execs into it, and before PostgreSQL 17 the
# postmaster treats any child that exits otherwise as a crashed backend and restarts every
# session.
memory_guard_main() {
	trap 'exit 0' TERM INT HUP
	memory_guard_settings
	if [ "${MEMORY_GUARD_ENABLED}" != "true" ]
	then
		memory_log LOG "memory guard off (MEMORY_GUARD_ENABLED=${MEMORY_GUARD_ENABLED})."
		exit 0
	fi
	memory_cgroup
	reading=$(memory_read) || reading=
	if [ -z "${reading}" ] || [ "${reading}" = unlimited ]
	then
		memory_log LOG "memory guard has nothing to watch: cgroup ${MEMORY_CGROUP} under ${MEMORY_CGROUP_DIR} has ${reading:-no readable} memory limit."
		exit 0
	fi
	MEMORY_GUARD_STATE_DIR=$(mktemp -d) || exit 0
	# shellcheck disable=SC2086  # four numbers
	set -- ${reading}
	memory_log LOG "memory guard on: cgroup ${MEMORY_CGROUP}, limit $3 MB, now $1% ($2 MB in use, page cache left out); every ${MEMORY_GUARD_INTERVAL}s (${MEMORY_GUARD_FAST_INTERVAL}s from ${MEMORY_GUARD_IDLE_PERC}% up); ends idle sessions at ${MEMORY_GUARD_IDLE_PERC}% (up to ${MEMORY_GUARD_IDLE_BATCH} a pass), the largest busy one at ${MEMORY_GUARD_ACTIVE_PERC}% (cancel, then terminate), the largest of any state at ${MEMORY_GUARD_CRITICAL_PERC}% (up to ${MEMORY_GUARD_CRITICAL_BATCH} a pass); only by pg_cancel_backend and pg_terminate_backend, never superuser, replication or background processes; ${4} OOM kill(s) recorded so far."
	[ "$4" -ge 0 ] && memory_guard_state oom_kill "$4"
	while :
	do
		( memory_guard_tick ) || true
		# Faster under pressure: memory can grow by gigabytes in a few seconds.
		if [ "$(memory_guard_state level)" = normal ] || [ -z "$(memory_guard_state level)" ]
		then
			sleep "${MEMORY_GUARD_INTERVAL}" || sleep 2 || true
		else
			sleep "${MEMORY_GUARD_FAST_INTERVAL}" || sleep 1 || true
		fi
	done
}
