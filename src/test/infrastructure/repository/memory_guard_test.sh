#!/bin/bash

# Tests for the memory guard and the OOM targeting of psql_memory.sh. Runs on the host, with no
# docker and no server: the guard is pointed at a fake cgroup folder and a fake /proc, and psql is
# a stub that lists canned sessions and records the statements the guard sends. The guard itself
# runs under sh (dash where it is the system shell), as in the image.
#
#   bash src/test/infrastructure/repository/memory_guard_test.sh
#
# Exits non-zero when any test fails.

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
SCRIPTS=${ROOT}/src/main/infrastructure/repository/script/psql
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
pass=0; fail=0

ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# psql stub: the session list from ${WORK}/sessions for the listing query, "t" for a cancel or
# terminate; every statement is appended to ${WORK}/psql.log. ${WORK}/psql.fail makes it fail.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/psql" <<'EOF'
#!/bin/sh
for last; do :; done
printf '%s\n' "${last}" | tr '\n' ' ' >> "${STUB_DIR}/psql.log"; echo >> "${STUB_DIR}/psql.log"
[ -f "${STUB_DIR}/psql.fail" ] && { echo "psql: error: connection refused" >&2; exit 2; }
case "${last}" in
	*pg_terminate_backend*|*pg_cancel_backend*) echo t ;;
	*pg_stat_activity*) cat "${STUB_DIR}/sessions" ;;
esac
EOF
chmod +x "${WORK}/bin/psql"

# Fake cgroup v2: limit, use (MB), page cache (MB), oom kills.
cgroup() { # limit-mb used-mb file-mb oom-kills [oom-group]
	mkdir -p "${WORK}/cg"
	echo $(( $1 * 1048576 )) > "${WORK}/cg/memory.max"
	echo $(( ($2 + $3) * 1048576 )) > "${WORK}/cg/memory.current"
	printf 'anon %d\nfile %d\nactive_file %d\ninactive_file %d\nshmem 0\n' $(( $2 * 1048576 )) $(( $3 * 1048576 )) $(( $3 * 524288 )) $(( $3 * 524288 )) > "${WORK}/cg/memory.stat"
	printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill %d\n' "$4" > "${WORK}/cg/memory.events"
	echo "${5:-0}" > "${WORK}/cg/memory.oom.group"
}

# Fake sessions: pid, private MB (RssAnon; VmPTE adds 1 MB), backend type, state, user, query.
# A parallel worker names its leader in the state column.
sessions() { # "pid mb type state user query"...
	: > "${WORK}/sessions"
	rm -rf "${WORK}/proc"
	for row in "$@"; do
		read -r pid mb type state user query <<< "${row}"
		leader=${pid}
		[ "${type}" = worker ] && { leader=${state}; state=active; user=app; }
		mkdir -p "${WORK}/proc/${pid}"
		printf 'Name:\tpostgres\nRssAnon:\t%d kB\nVmPTE:\t1024 kB\n' $(( mb * 1024 - 1024 )) > "${WORK}/proc/${pid}/status"
		btype="client backend"; [ "${type}" = worker ] && btype="parallel worker"
		printf '%s\t%s\t%s\t%s\t%s\tappdb\tapp-%s\t%s\n' "${pid}" "${leader}" "${btype}" "${state//_/ }" "${user}" "${pid}" "${query//_/ }" >> "${WORK}/sessions"
	done
}

# Runs guard passes under sh with the given settings; prints the guard's log (stderr) and keeps
# the statements in ${WORK}/psql.log. State carries over between the passes of one call.
guard() { # passes [VAR=value...]
	local passes=$1; shift
	: > "${WORK}/psql.log"
	rm -rf "${WORK}/state"; mkdir -p "${WORK}/state"
	env PATH="${WORK}/bin:${PATH}" STUB_DIR="${WORK}" MEMORY_CGROUP_DIR="${WORK}/cg" MEMORY_PROC_DIR="${WORK}/proc" \
		MEMORY_GUARD_STATE_DIR="${WORK}/state" PGDATA="${WORK}/pgdata" "$@" sh -c "
		. '${SCRIPTS}/psql_memory.sh'
		memory_guard_settings; memory_cgroup
		echo \"\$(memory_read | cut -d' ' -f4)\" > '${WORK}/state/oom_kill'
		i=0; while [ \$i -lt ${passes} ]; do ( memory_guard_tick ); i=\$((i+1)); [ -f '${WORK}/between' ] && . '${WORK}/between'; done" 2>&1
}
terminated() { grep -o 'pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid = [0-9]*' "${WORK}/psql.log" | awk '{print $NF}' | sort -n | tr '\n' ' '; }
canceled() { grep -o 'pg_cancel_backend(pid) FROM pg_stat_activity WHERE pid = [0-9]*' "${WORK}/psql.log" | awk '{print $NF}' | sort -n | tr '\n' ' '; }
listed() { grep -c 'LEFT JOIN pg_roles' "${WORK}/psql.log"; }

# 1. Reading the cgroup: page cache is left out of the use; no limit is "unlimited"; v1 works.
cgroup 1000 500 400 0
out=$(env MEMORY_CGROUP_DIR="${WORK}/cg" sh -c ". '${SCRIPTS}/psql_memory.sh'; memory_cgroup; memory_read")
[ "${out}" = "50 500 1000 0" ] && ok "v2: 500 MB in use of 1000 MB, 400 MB of page cache left out (${out})" || bad "v2 reading '${out}'"
echo max > "${WORK}/cg/memory.max"
out=$(env MEMORY_CGROUP_DIR="${WORK}/cg" sh -c ". '${SCRIPTS}/psql_memory.sh'; memory_cgroup; memory_read")
[ "${out}" = unlimited ] && ok "v2: memory.max=max reads as unlimited" || bad "v2 unlimited reading '${out}'"
mkdir -p "${WORK}/cg1/memory"
echo 2147483648 > "${WORK}/cg1/memory/memory.limit_in_bytes"
echo 1932735283 > "${WORK}/cg1/memory/memory.usage_in_bytes"
printf 'cache 0\ntotal_active_file 0\ntotal_inactive_file 0\n' > "${WORK}/cg1/memory/memory.stat"
printf 'oom_kill_disable 0\nunder_oom 0\noom_kill 3\n' > "${WORK}/cg1/memory/memory.oom_control"
out=$(env MEMORY_CGROUP_DIR="${WORK}/cg1" sh -c ". '${SCRIPTS}/psql_memory.sh'; memory_cgroup; echo \${MEMORY_CGROUP}; memory_read" | tr '\n' ' ')
[ "${out}" = "v1 89 1843 2048 3 " ] && ok "v1 fallback: ${out}" || bad "v1 reading '${out}'"
echo 9223372036854771712 > "${WORK}/cg1/memory/memory.limit_in_bytes"
out=$(env MEMORY_CGROUP_DIR="${WORK}/cg1" sh -c ". '${SCRIPTS}/psql_memory.sh'; memory_cgroup; memory_read")
[ "${out}" = unlimited ] && ok "v1: the page-rounded 2^63 reads as unlimited" || bad "v1 unlimited reading '${out}'"

# The sessions most tests share: idle ones of 10 to 90 MB, one too small to bother with, busy ones.
standard_sessions() {
	sessions "101 90 client idle app select_1" "102 70 client idle app select_2" "103 60 client idle app select_3" \
		"104 50 client idle app select_4" "105 40 client idle app select_5" "106 30 client idle app select_6" \
		"107 4 client idle app tiny" "201 300 client active app select_*_from_big_order_by_x" "202 200 client active app hash_join" \
		"203 20 client idle_in_transaction app update"
}

# 2. Below the idle threshold nothing is listed or ended.
cgroup 1000 840 500 0; standard_sessions
guard 1 >/dev/null
[ "$(listed)" = 0 ] && [ -z "$(terminated)$(canceled)" ] && ok "84% (page cache aside): no session listed or ended" || bad "84%: listed $(listed), terminated '$(terminated)', canceled '$(canceled)'"

# 3. At the idle threshold the 5 largest idle sessions are terminated, none of the busy ones, none
# under MEMORY_GUARD_MIN_PRIVATE_MB.
cgroup 1000 870 0 0; standard_sessions
log=$(guard 1)
[ "$(terminated)" = "101 102 103 104 105 " ] && [ -z "$(canceled)" ] && ok "87%: the 5 largest idle sessions are terminated, nothing busy" \
	|| bad "87%: terminated '$(terminated)', canceled '$(canceled)'"
grep -q "pid = 101 AND backend_type = 'client backend' AND state = 'idle'" "${WORK}/psql.log" && ok "an idle session is only terminated while still idle" \
	|| bad "the terminate statement does not check the session is still idle"
line=$(echo "${log}" | grep 'pid=101 ')
[[ "${line}" == *"MEMORY_GUARD: WARN: memory at 87% of 1000 MB"*"terminating pid=101 usename=app datname=appdb application_name=\"app-101\" state=\"idle\" private_mb=90 query=\"select 1\" result=ok" ]] \
	&& ok "each action is one WARN line with pid, user, database, application, state, private MB, memory % and query" || bad "action line: '${line}'"
[ "$(echo "${log}" | grep -c 'at or above 85%')" = 1 ] && ok "crossing the idle threshold is logged once" || bad "threshold crossing logged $(echo "${log}" | grep -c 'at or above 85%') times"
guard 1 MEMORY_GUARD_IDLE_BATCH=2 >/dev/null
[ "$(terminated)" = "101 102 " ] && ok "MEMORY_GUARD_IDLE_BATCH=2 bounds a pass to 2" || bad "batch of 2 terminated '$(terminated)'"

# 4. At the active threshold the largest busy session's query is canceled; when it is still the
# largest on the next pass, it is terminated.
cgroup 1000 930 0 0; standard_sessions
guard 1 >/dev/null
[ "$(canceled)" = "201 " ] && [[ "$(terminated)" != *201* ]] && ok "93%: the largest busy query (pid 201) is canceled, not terminated" \
	|| bad "93%: canceled '$(canceled)', terminated '$(terminated)'"
guard 2 >/dev/null
[ "$(canceled)" = "201 " ] && [[ "$(terminated)" == *201* ]] && ok "93% on the next pass: pid 201, still the largest, is terminated" \
	|| bad "93% two passes: canceled '$(canceled)', terminated '$(terminated)'"
sessions "203 500 client idle_in_transaction app update" "201 300 client active app select"
guard 1 >/dev/null
[ "$(terminated)" = "203 " ] && [ -z "$(canceled)" ] && ok "a session idle in a transaction has no query to cancel and is terminated at once" \
	|| bad "idle in transaction: terminated '$(terminated)', canceled '$(canceled)'"
# Pressure gone after the cancel: nothing more happens, and the cancel is forgotten.
cgroup 1000 930 0 0; standard_sessions
echo "echo $(( 500 * 1048576 )) > '${WORK}/cg/memory.current'" > "${WORK}/between"
guard 2 >/dev/null
rm -f "${WORK}/between"
[ "$(canceled)" = "201 " ] && [[ "$(terminated)" != *201* ]] && ok "once memory is back under the thresholds the canceled session is left alone" \
	|| bad "after relief: canceled '$(canceled)', terminated '$(terminated)'"

# 5. Parallel workers' memory counts for the session that leads them.
cgroup 1000 930 0 0
sessions "301 300 client active app big" "302 20 client active app parallel" "303 400 worker 302" "304 400 worker 302"
guard 1 >/dev/null
[ "$(canceled)" = "302 " ] && ok "a leader with 800 MB in its parallel workers is the largest busy session" || bad "parallel leader: canceled '$(canceled)'"

# 6. At the critical threshold the largest sessions are terminated whatever their state, until they
# hold what must be freed to get back under the active threshold, within MEMORY_GUARD_CRITICAL_BATCH.
cgroup 1000 970 0 0; standard_sessions
guard 1 >/dev/null
# 970 - 920 = 50 MB to free: the 300 MB busy session covers it alone.
[ "$(terminated)" = "201 " ] && [ -z "$(canceled)" ] && ok "97%: the largest session (busy, 300 MB) is terminated, enough to free 50 MB" \
	|| bad "97%: terminated '$(terminated)', canceled '$(canceled)'"
cgroup 1000 990 0 0
sessions "401 30 client active app a" "402 25 client idle app b" "403 20 client active app c" "404 15 client idle app d" "405 10 client active app e"
guard 1 >/dev/null
[ "$(terminated)" = "401 402 403 " ] && ok "99%: busy and idle sessions are terminated, largest first, until 70 MB is covered" \
	|| bad "99%: terminated '$(terminated)'"
guard 1 MEMORY_GUARD_CRITICAL_BATCH=2 >/dev/null
[ "$(terminated)" = "401 402 " ] && ok "MEMORY_GUARD_CRITICAL_BATCH=2 bounds the critical pass" || bad "critical batch of 2 terminated '$(terminated)'"
grep -v 'LEFT JOIN pg_roles' "${WORK}/psql.log" | grep -qv -E 'SELECT pg_(terminate|cancel)_backend\(pid\)' \
	&& bad "the guard sent something other than pg_cancel_backend / pg_terminate_backend" \
	|| ok "the guard only ever cancels or terminates (no kill signal)"

# 7. The session list asks for client backends that are not superusers (walsenders and background
# processes have other backend types), never the guard's own session.
grep -q "a.backend_type = 'client backend' AND r.rolsuper IS FALSE" "${WORK}/psql.log" && grep -q 'a.pid <> pg_backend_pid()' "${WORK}/psql.log" \
	&& ok "the listing excludes superusers, replication, background processes and the guard itself" || bad "the listing does not filter sessions as expected"

# 8. Nothing the guard may end: one WARN line, not one per pass.
cgroup 1000 930 0 0
sessions "501 4 client idle app tiny"
log=$(guard 3)
[ "$(echo "${log}" | grep -c 'no session the guard may end')" = 1 ] && [ -z "$(terminated)$(canceled)" ] && ok "with nothing to end the guard says so once" \
	|| bad "nothing to end: '${log}'"

# 9. An OOM kill since the last pass is logged as a crash-recovery event, with the postmaster's state.
cgroup 1000 500 0 0; standard_sessions
mkdir -p "${WORK}/pgdata"; echo $$ > "${WORK}/pgdata/postmaster.pid"
echo "sed -i 's/^oom_kill .*/oom_kill 2/' '${WORK}/cg/memory.events'" > "${WORK}/between"
log=$(guard 2)
rm -f "${WORK}/between"
line=$(echo "${log}" | grep 'OOM kill')
[[ "${line}" == *"MEMORY_GUARD: ERROR: OOM kill: crash recovery."*"killed 2 process(es)"*"oom_kill 0 -> 2"*"postmaster pid $$ still running"* ]] \
	&& ok "an oom_kill increment is logged as crash recovery, with the postmaster still running" || bad "oom_kill line: '${line}'"
[ "$(echo "${log}" | grep -c 'OOM kill')" = 1 ] && ok "the oom_kill increment is logged once" || bad "oom_kill logged $(echo "${log}" | grep -c 'OOM kill') times"

# 10. psql failures are tolerated and logged once a minute, not every pass.
cgroup 1000 900 0 0; standard_sessions; touch "${WORK}/psql.fail"
log=$(guard 3)
rm -f "${WORK}/psql.fail"
[ "$(echo "${log}" | grep -c 'could not be listed')" = 1 ] && [ -z "$(terminated)" ] && ok "a failing psql is logged once and ends nothing" \
	|| bad "failing psql: '${log}'"

# 11. The loop survives readings that are not numbers, exits 0 on SIGTERM (it is the postmaster's
# child, and before PostgreSQL 17 any other exit restarts every session), and exits 0 with a line
# when off or unlimited.
cgroup 1000 500 0 0
loop_status() { # VAR=value...
	env PATH="${WORK}/bin:${PATH}" STUB_DIR="${WORK}" MEMORY_CGROUP_DIR="${WORK}/cg" MEMORY_PROC_DIR="${WORK}/proc" \
		MEMORY_GUARD_INTERVAL=0.2 MEMORY_GUARD_FAST_INTERVAL=0.1 "$@" sh "${SCRIPTS}/psql_memory_guard.sh" 2> "${WORK}/loop.log" &
	local pid=$!
	sleep 0.5
	echo garbage > "${WORK}/cg/memory.current"
	sleep 0.6
	if kill -0 "${pid}" 2>/dev/null; then echo -n "running "; fi
	kill -TERM "${pid}" 2>/dev/null
	wait "${pid}"
	echo "status $?"
}
out=$(loop_status)
[ "${out}" = "running status 0" ] && ok "the loop keeps running on garbage readings and exits 0 on SIGTERM" || bad "loop: '${out}' $(cat "${WORK}/loop.log")"
cgroup 1000 500 0 0
out=$(loop_status MEMORY_GUARD_ENABLED=false)
grep -q 'MEMORY_GUARD: LOG: memory guard off' "${WORK}/loop.log" && [ "${out}" = "status 0" ] && ok "MEMORY_GUARD_ENABLED=false exits 0 with a line" || bad "disabled: '${out}' $(cat "${WORK}/loop.log")"
echo max > "${WORK}/cg/memory.max"
out=$(loop_status)
grep -q 'nothing to watch' "${WORK}/loop.log" && [ "${out}" = "status 0" ] && ok "with no memory limit the guard exits 0 with a line" || bad "unlimited: '${out}' $(cat "${WORK}/loop.log")"
cgroup 1000 500 0 0
loop_status MEMORY_GUARD_IDLE_PERC=abc MEMORY_GUARD_FAST_INTERVAL=0 >/dev/null
grep -q 'MEMORY_GUARD_IDLE_PERC=abc is not an integer; using 85' "${WORK}/loop.log" && grep -q 'MEMORY_GUARD_FAST_INTERVAL=0 is not a positive number' "${WORK}/loop.log" \
	&& grep -q 'idle sessions at 85%' "${WORK}/loop.log" && ok "bad settings fall back to their defaults with a warning" || bad "bad settings: $(cat "${WORK}/loop.log")"

# 12. Faster passes under pressure: at 90% the guard lists sessions every MEMORY_GUARD_FAST_INTERVAL.
cgroup 1000 900 0 0; sessions "601 4 client idle app tiny"; : > "${WORK}/psql.log"
env PATH="${WORK}/bin:${PATH}" STUB_DIR="${WORK}" MEMORY_CGROUP_DIR="${WORK}/cg" MEMORY_PROC_DIR="${WORK}/proc" \
	MEMORY_GUARD_INTERVAL=5 MEMORY_GUARD_FAST_INTERVAL=0.2 sh "${SCRIPTS}/psql_memory_guard.sh" 2>/dev/null &
pid=$!; sleep 2; kill -TERM "${pid}"; wait "${pid}" 2>/dev/null
[ "$(listed)" -ge 4 ] && ok "under pressure the guard checks every MEMORY_GUARD_FAST_INTERVAL ($(listed) passes in 2 s)" || bad "fast interval: $(listed) passes in 2 s"

# 13. OOM targeting: the children's score is exported for PostgreSQL and logged with the cgroup's
# limit and oom.group; oom.group=1 is warned about; off unsets it.
cgroup 1000 500 0 0 1
out=$(env MEMORY_CGROUP_DIR="${WORK}/cg" sh -c ". '${SCRIPTS}/psql_memory.sh'; psql_oom_target; echo \"file=\${PG_OOM_ADJUST_FILE} value=\${PG_OOM_ADJUST_VALUE}\"" 2>&1)
[[ "${out}" == *"MEMORY_GUARD: LOG: OOM targeting on: postmaster oom_score_adj="*"server processes oom_score_adj=900"*"memory.max=1048576000, memory.oom.group=1"* ]] \
	&& [[ "${out}" == *"file=/proc/self/oom_score_adj value=900"* ]] && ok "OOM targeting exports PG_OOM_ADJUST_FILE/VALUE=900 and logs scores, memory.max and oom.group" \
	|| bad "OOM targeting: '${out}'"
[[ "${out}" == *"MEMORY_GUARD: WARN: memory.oom.group=1"*"cannot protect the postmaster"* ]] && ok "memory.oom.group=1 is warned about" || bad "no oom.group warning: '${out}'"
out=$(env MEMORY_CGROUP_DIR="${WORK}/cg" OOM_TARGETING_ENABLED=false PG_OOM_ADJUST_FILE=x sh -c ". '${SCRIPTS}/psql_memory.sh'; psql_oom_target; echo \"file=\${PG_OOM_ADJUST_FILE}\"" 2>&1)
[[ "${out}" == *"OOM targeting off"* ]] && [[ "${out}" == *"file=" ]] && ok "OOM_TARGETING_ENABLED=false unsets it and says so" || bad "targeting off: '${out}'"
out=$(env MEMORY_CGROUP_DIR="${WORK}/cg" OOM_CHILD_SCORE_ADJ=-500 sh -c ". '${SCRIPTS}/psql_memory.sh'; psql_oom_target" 2>&1)
[[ "${out}" == *"OOM_CHILD_SCORE_ADJ=-500 is not above the postmaster's"* ]] && ok "a child score not above the postmaster's is warned about" || bad "low child score: '${out}'"

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
