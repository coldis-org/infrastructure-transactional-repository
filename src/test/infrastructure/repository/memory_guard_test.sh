#!/bin/sh

# Tests for the memory guard and the OOM targeting of psql_memory.sh. Runs on the host under sh
# (dash), with no docker and no server: the guard is pointed at a fake cgroup folder, a fake /proc
# and a fake clock (/proc/uptime), and psql is a stub that lists canned sessions and records the
# statements the guard sends.
#
#   sh src/test/infrastructure/repository/memory_guard_test.sh
#
# Exits non-zero when any test fails.

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
SCRIPTS=${ROOT}/src/main/infrastructure/repository/script/psql
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
LC_ALL=C
export LC_ALL
pass=0
fail=0
: > "${WORK}/all.log"

ok() { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
# check <description> <command...>: passes when the command succeeds.
check() {
	check_name=$1
	shift
	if "$@"; then ok "${check_name}"; else bad "${check_name}"; fi
}
# has <text> <pattern>: the text matches the shell pattern.
has() {
	# shellcheck disable=SC2254  # $2 is a pattern
	case "$1" in
		$2) return 0 ;;
	esac
	return 1
}
count() { # text fixed-string
	printf '%s\n' "$1" | grep -c -F -- "$2"
}

# psql stub. The listing query gets ${WORK}/sessions; the action statement gets one "<pid> t" per
# session in its VALUES list ("<pid> skipped" for pids in ${WORK}/gone). Every statement is one
# line of ${WORK}/psql.log. ${WORK}/psql.fail makes it fail; ${WORK}/psql.slow makes every call
# take 300 ms on the fake clock, or as many seconds as the file holds.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/psql" <<'EOF'
#!/bin/sh
for last; do :; done
printf '%s\n' "${last}" | tr '\n' ' ' >> "${STUB_DIR}/psql.log"; echo >> "${STUB_DIR}/psql.log"
if [ -f "${STUB_DIR}/psql.slow" ]
then
	read -r up _ < "${STUB_DIR}/uptime"
	slow=; read -r slow < "${STUB_DIR}/psql.slow" || true
	awk -v u="${up}" -v s="${slow:-0.30}" 'BEGIN { printf "%.2f\n", u + s }' > "${STUB_DIR}/uptime"
fi
[ -f "${STUB_DIR}/psql.fail" ] && { echo "psql: error: connection to server failed: \"no\" such socket" >&2; exit 2; }
case "${last}" in
	*'FROM (VALUES'*)
		printf '%s\n' "${last}" | grep -o "([0-9]*, [0-9]*, '[a-z]*'" | tr -d "(," | while read -r pid _
		do
			if grep -qx "${pid}" "${STUB_DIR}/gone" 2>/dev/null; then printf '%s\tskipped\n' "${pid}"; else printf '%s\ttrue\n' "${pid}"; fi
		done
		;;
	*'LEFT JOIN pg_roles r ON r.oid = a.usesysid'*) cat "${STUB_DIR}/sessions" ;;
esac
EOF
# grep wrapper: records the files the guard reads, then runs grep.
REAL_GREP=$(command -v grep)
cat > "${WORK}/bin/grep" <<EOF
#!/bin/sh
for arg; do case "\${arg}" in */status) echo "\${arg}" >> "${WORK}/grep.log" ;; esac; done
exec "${REAL_GREP}" "\$@"
EOF
chmod +x "${WORK}/bin/psql" "${WORK}/bin/grep"

# Fake clock, moved by "advance <ms>"; "use <MB>" sets the cgroup's use. Both are also commands,
# so that ${WORK}/between can run them between passes.
clock() { echo "$1" > "${WORK}/uptime"; }
cat > "${WORK}/bin/advance" <<EOF
#!/bin/sh
read -r up _ < "${WORK}/uptime"
awk -v u="\${up}" -v d="\$1" 'BEGIN { printf "%.2f\\n", u + d / 1000 }' > "${WORK}/uptime"
EOF
cat > "${WORK}/bin/use" <<EOF
#!/bin/sh
echo \$(( \$1 * 1048576 )) > "${WORK}/cg/memory.current"
EOF
chmod +x "${WORK}/bin/advance" "${WORK}/bin/use"
advance() { "${WORK}/bin/advance" "$@"; }
use() { "${WORK}/bin/use" "$@"; }
clock 1000.00

# Fake cgroup v2: limit, use (MB), page cache (MB), oom kills, oom.group.
cgroup() { # limit-mb used-mb file-mb oom-kills [oom-group]
	rm -rf "${WORK}/cg"
	mkdir -p "${WORK}/cg"
	echo $(( $1 * 1048576 )) > "${WORK}/cg/memory.max"
	echo $(( ($2 + $3) * 1048576 )) > "${WORK}/cg/memory.current"
	printf 'anon %d\nfile %d\nactive_file %d\ninactive_file %d\nshmem 0\n' $(( $2 * 1048576 )) $(( $3 * 1048576 )) $(( $3 * 524288 )) $(( $3 * 524288 )) > "${WORK}/cg/memory.stat"
	printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill %d\n' "$4" > "${WORK}/cg/memory.events"
	echo "${5:-0}" > "${WORK}/cg/memory.oom.group"
	echo max > "${WORK}/cg/memory.high"
	echo 0 > "${WORK}/cg/memory.swap.max"
}

# Fake sessions: "pid mb type state user query" (underscores are spaces). A parallel worker
# ("worker") names its leader in the state column. The query id is pid * 7, none for pid 105.
sessions() {
	: > "${WORK}/sessions"
	rm -rf "${WORK}/proc"
	for row in "$@"
	do
		# shellcheck disable=SC2086  # split the row
		set -- ${row}
		pid=$1 mb=$2 type=$3 state=$4 user=$5 query=$6
		leader=${pid}
		btype="client backend"
		if [ "${type}" = worker ]; then leader=${state}; state=active; user=app; btype="parallel worker"; fi
		mkdir -p "${WORK}/proc/${pid}"
		printf 'Name:\tpostgres\nRssAnon:\t%d kB\nVmPTE:\t1024 kB\n' $(( mb * 1024 - 1024 )) > "${WORK}/proc/${pid}/status"
		qid=$(( pid * 7 ))
		[ "${pid}" = 105 ] && qid=
		printf '%s\t%s\t%s\t%s\t%s\t%s\tappdb\tapp-%s\t%s\t%s\n' "${pid}" "${leader}" "${btype}" "$(echo "${state}" | tr _ ' ')" \
			$(( 1700000000000000 + pid )) "${user}" "${pid}" "${qid}" "$(echo "${query}" | tr _ ' ')" >> "${WORK}/sessions"
	done
}
standard_sessions() {
	sessions "101 90 client idle app select_1" "102 70 client idle app select_2" "103 60 client idle app select_3" \
		"104 50 client idle app select_4" "105 40 client idle app select_\"5\"" "106 30 client idle app select_6" \
		"107 4 client idle app tiny" "201 300 client active app select_*_from_big_order_by_x" "202 200 client active app hash_join" \
		"203 20 client idle_in_transaction app update"
}

ENVS="PATH=${WORK}/bin:${PATH} STUB_DIR=${WORK} MEMORY_CGROUP_DIR=${WORK}/cg MEMORY_PROC_DIR=${WORK}/proc MEMORY_UPTIME_FILE=${WORK}/uptime PGDATA=${WORK}/pgdata MEMORY_GUARD_PAUSE_FILE=${WORK}/pause"

# Runs guard passes under sh, enforcing unless told otherwise; prints the guard's log (stderr)
# and keeps the statements in ${WORK}/psql.log. State carries over between the passes of one
# call; ${WORK}/between, when present, is sourced between passes.
guard() { # passes [VAR=value...]
	guard_passes=$1
	shift
	: > "${WORK}/psql.log"
	: > "${WORK}/grep.log"
	rm -rf "${WORK}/state"
	mkdir -p "${WORK}/state"
	# shellcheck disable=SC2086  # ENVS is a list of assignments
	env ${ENVS} MEMORY_GUARD_STATE_DIR="${WORK}/state" MEMORY_GUARD_MODE=enforce "$@" sh -c "
		. '${SCRIPTS}/psql_memory.sh'
		memory_guard_settings; memory_cgroup
		set -- \$(memory_read); memory_guard_init \"\${4:--1}\"
		i=0; while [ \$i -lt ${guard_passes} ]; do ( memory_guard_tick ); i=\$((i+1)); [ -f '${WORK}/between' ] && . '${WORK}/between'; done" 2>&1 \
		| tee -a "${WORK}/all.log"
}
# Pids in the action statements, by action.
acted() { # terminate|cancel
	grep -o "([0-9]*, [0-9]*, '$1'" "${WORK}/psql.log" | tr -d '(,' | awk '{ print $1 }' | sort -n | tr '\n' ' '
}
terminated() { acted terminate; }
canceled() { acted cancel; }
listed() { grep -c 'LEFT JOIN pg_roles r ON r.oid = a.usesysid' "${WORK}/psql.log"; }
statements() { grep -c 'FROM (VALUES' "${WORK}/psql.log"; }
state() { sed -n "s/^$1=//p" "${WORK}/state/state"; }
memread() { # cgroup-dir
	env MEMORY_CGROUP_DIR="$1" sh -c ". '${SCRIPTS}/psql_memory.sh'; memory_cgroup; memory_read"
}

# 1. Reading the cgroup.
cgroup 1000 500 400 0
out=$(memread "${WORK}/cg")
check "v2: 500 MB in use of 1000 MB, 400 MB of page cache left out (${out})" [ "${out}" = "50 500 1000 0 512000 1024000" ]
echo max > "${WORK}/cg/memory.max"
check "v2: memory.max=max reads as unlimited" [ "$(memread "${WORK}/cg")" = unlimited ]
mkdir -p "${WORK}/cg1/memory"
echo 1048576000 > "${WORK}/cg1/memory/memory.limit_in_bytes"
echo 943718400 > "${WORK}/cg1/memory/memory.usage_in_bytes"
# Real v1 memory.stat: the cgroup's own counters and the hierarchical total_* ones, both.
printf 'cache 0\nactive_file 104857600\ninactive_file 104857600\ntotal_active_file 104857600\ntotal_inactive_file 104857600\n' > "${WORK}/cg1/memory/memory.stat"
printf 'oom_kill_disable 0\nunder_oom 0\noom_kill 3\n' > "${WORK}/cg1/memory/memory.oom_control"
out=$(memread "${WORK}/cg1")
check "v1 with plain and total_* page cache: 900 - 200 = 700 MB (70%), not counted twice (${out})" has "${out}" "70 700 1000 3 *"
printf 'active_file 104857600\ninactive_file 104857600\n' > "${WORK}/cg1/memory/memory.stat"
out=$(memread "${WORK}/cg1")
check "v1 without total_*: the cgroup's own counters are used (${out})" has "${out}" "70 700 1000 3 *"
echo 9223372036854771712 > "${WORK}/cg1/memory/memory.limit_in_bytes"
check "v1: the page-rounded 2^63 reads as unlimited" [ "$(memread "${WORK}/cg1")" = unlimited ]

# 2. Below the idle threshold nothing is listed or ended.
cgroup 1000 840 500 0; standard_sessions
guard 1 >/dev/null
if [ "$(listed)" = 0 ] && [ -z "$(terminated)$(canceled)" ]; then ok "84% (page cache aside): no session listed or ended"; else bad "84% (page cache aside): no session listed or ended"; fi

# 3. At the idle threshold the 5 largest idle sessions are terminated in one statement.
cgroup 1000 870 0 0; standard_sessions
log=$(guard 1)
if [ "$(terminated)" = "101 102 103 104 105 " ] && [ -z "$(canceled)" ]; then ok "87%: the 5 largest idle sessions are terminated, nothing busy, nothing under 16 MB"; else bad "87%: the 5 largest idle sessions are terminated, nothing busy, nothing under 16 MB"; fi
if [ "$(listed)" = 1 ] && [ "$(statements)" = 1 ] && [ "$(wc -l < "${WORK}/psql.log")" = 2 ]; then ok "one listing and one action statement for the whole pass"; else bad "one listing and one action statement for the whole pass"; fi
action=$(grep 'FROM (VALUES' "${WORK}/psql.log")
check "the action statement re-checks backend_start, client backend, rolsuper and idle state" \
	has "${action}" "*(101, 1700000000000101, 'terminate', 'idle')*extract(epoch FROM a.backend_start)*= v.backend_start::bigint*backend_type = 'client backend'*a.state = v.expected_state*rolsuper IS FALSE*"
line=$(printf '%s\n' "${log}" | grep 'pid=101 ')
check "action line: fields in order, query_id and capped query" has "${line}" \
	'* MEMORY_GUARD: WARN: event=action action=terminate stage=idle pid=101 usename="app" datname="appdb" application_name="app-101" state="idle" private_mb=90 used_pct=87 used_mb=870 limit_mb=1000 result=ok query_id=707 query="select 1"'
line=$(printf '%s\n' "${log}" | grep 'pid=105 ')
check "action line: no query_id when the server has none; inner double quotes made single" has "${line}" "* query_id= query=\"select '5'\""
check "crossing into stage idle is logged once" [ "$(count "${log}" 'event=stage from=normal to=idle used_pct=87 used_mb=870 limit_mb=1000')" = 1 ]
guard 1 MEMORY_GUARD_IDLE_BATCH=2 >/dev/null
check "MEMORY_GUARD_IDLE_BATCH=2 bounds a pass to 2" [ "$(terminated)" = "101 102 " ]
echo 102 > "${WORK}/gone"
log=$(guard 1 MEMORY_GUARD_IDLE_BATCH=2)
rm -f "${WORK}/gone"
check "a session gone or changed since the listing is result=skipped" has "${log}" "*pid=102 *result=skipped*"

# 4. Pending credit: a session terminated in the last 5 s is not ended again, and stage critical
# frees less while it exits.
cgroup 1000 870 0 0; standard_sessions
guard 2 >/dev/null
check "the next pass does not terminate the still-exiting sessions again, only the next idle one" [ "$(terminated)" = "101 102 103 104 105 106 " ]
echo "advance 6000" > "${WORK}/between"
guard 2 MEMORY_GUARD_IDLE_BATCH=1 >/dev/null
rm -f "${WORK}/between"
check "after 5 s the credit expires and a session still there can be chosen again" [ "$(terminated)" = "101 101 " ]
cgroup 1000 970 0 0; standard_sessions
log=$(guard 2)
check "97%, two passes: 201 (300 MB) covers the 50 MB to free; the next pass ends nothing more" [ "$(terminated)" = "201 " ]
check "while the credit covers the need it is not reported as no candidate" [ "$(count "${log}" event=no_candidate)" = 0 ]

# 5. Stage active: the largest busy query is canceled, terminated after the grace when it is still
# the largest; a session idle in a transaction is terminated at once.
cgroup 1000 930 0 0; standard_sessions
guard 1 >/dev/null
if [ "$(canceled)" = "201 " ] && ! has "$(terminated)" "*201*"; then ok "93%: the largest busy query (pid 201) is canceled, not terminated"; else bad "93%: the largest busy query (pid 201) is canceled, not terminated"; fi
guard 2 >/dev/null
if [ "$(canceled)" = "201 " ] && ! has "$(terminated)" "*201*"; then ok "93% on the next pass within the grace: no terminate yet"; else bad "93% on the next pass within the grace: no terminate yet"; fi
echo "advance 1000" > "${WORK}/between"
guard 2 >/dev/null
rm -f "${WORK}/between"
if [ "$(canceled)" = "201 " ] && has "$(terminated)" "*201*"; then ok "93% after MEMORY_GUARD_CANCEL_GRACE: pid 201, still the largest, is terminated"; else bad "93% after MEMORY_GUARD_CANCEL_GRACE: pid 201, still the largest, is terminated"; fi
sessions "203 500 client idle_in_transaction app update" "201 300 client active app select"
guard 1 >/dev/null
if [ "$(terminated)" = "203 " ] && [ -z "$(canceled)" ]; then ok "a session idle in a transaction is terminated at once"; else bad "a session idle in a transaction is terminated at once"; fi
cgroup 1000 930 0 0; standard_sessions
echo "use 500" > "${WORK}/between"
log=$(guard 2)
rm -f "${WORK}/between"
if [ "$(canceled)" = "201 " ] && ! has "$(terminated)" "*201*"; then ok "back under the thresholds: the canceled session is left alone"; else bad "back under the thresholds: the canceled session is left alone"; fi
check "back to normal after acting: one stage LOG line and one relief line" \
	has "${log}" "*LOG: event=stage from=active to=normal used_pct=50*LOG: event=relief duration_s=0 peak_pct=93 terminated=5 canceled=1*"

# 6. Parallel workers' memory counts for the session that leads them; /proc is read only for the
# listed client backends and their workers.
cgroup 1000 930 0 0
sessions "301 300 client active app big" "302 20 client active app parallel" "303 400 worker 302" "304 400 worker 302" "305 900 worker 999"
guard 1 >/dev/null
check "a leader with 800 MB in its parallel workers is the largest busy session" [ "$(canceled)" = "302 " ]
read_pids=$(sed 's|.*/proc/\([0-9]*\)/status|\1|' "${WORK}/grep.log" | sort -n | tr '\n' ' ')
check "/proc read only for listed client backends and their workers (${read_pids})" [ "${read_pids}" = "301 302 303 304 " ]

# 7. Stage critical.
cgroup 1000 970 0 0; standard_sessions
guard 1 >/dev/null
if [ "$(terminated)" = "201 " ] && [ -z "$(canceled)" ]; then ok "97%: the largest session (busy, 300 MB) is terminated, enough to free 50 MB"; else bad "97%: the largest session (busy, 300 MB) is terminated, enough to free 50 MB"; fi
cgroup 1000 990 0 0
sessions "401 30 client active app a" "402 25 client idle app b" "403 20 client active app c" "404 18 client idle app d" "405 17 client active app e"
guard 1 >/dev/null
check "99%: busy and idle sessions are terminated, largest first, until 70 MB is covered" [ "$(terminated)" = "401 402 403 " ]
guard 1 MEMORY_GUARD_CRITICAL_BATCH=2 >/dev/null
check "MEMORY_GUARD_CRITICAL_BATCH=2 bounds the critical pass" [ "$(terminated)" = "401 402 " ]

# 8. Only pg_cancel_backend and pg_terminate_backend, never a signal of the guard's own.
check "every statement is the listing or the cancel/terminate statement" [ "$(grep -v -c -e 'LEFT JOIN pg_roles r ON r.oid = a.usesysid' -e 'pg_terminate_backend(a.pid)' "${WORK}/psql.log")" = 0 ]
check "the guard never sends a signal itself (only kill -0)" [ "$(grep -v '^[[:space:]]*#' "${SCRIPTS}/psql_memory.sh" "${SCRIPTS}/psql_memory_guard.sh" | grep -E -c '(^|[^_a-z])kill +(-[A-Za-z]*[A-Z1-9]|-s |[0-9$"])|pkill|SIGKILL')" = 0 ]

# 9. The listing.
listing=$(grep 'LEFT JOIN pg_roles' "${WORK}/psql.log" | head -n 1)
check "the listing: non-superuser client backends, parallel workers, not the guard's own, backend_start, query_id" \
	has "${listing}" "*a.query_id*a.pid <> pg_backend_pid()*a.backend_type = 'client backend' AND r.rolsuper IS FALSE) OR a.backend_type = 'parallel worker'*"
check "the listing carries backend_start in microseconds" has "${listing}" "*extract(epoch FROM a.backend_start) * 1000000)::bigint*"
check "the query prefix is capped at MEMORY_GUARD_QUERY_CHARS (120)" has "${listing}" "*'?', 'g'), 120)*"
cgroup 1000 870 0 0; standard_sessions
guard 1 MEMORY_GUARD_QUERY_CHARS=0 >/dev/null
check "MEMORY_GUARD_QUERY_CHARS=0 asks for no query text" has "$(grep 'LEFT JOIN pg_roles' "${WORK}/psql.log")" "*'?', 'g'), 0)*"

# 10. Nothing the guard may end: one WARN line, not one per pass.
cgroup 1000 930 0 0
sessions "501 4 client idle app tiny"
log=$(guard 3)
if [ "$(count "${log}" 'WARN: event=no_candidate stage=active used_pct=93 min_private_mb=16')" = 1 ] && [ -z "$(terminated)$(canceled)" ]; then ok "with nothing to end the guard says so once"; else bad "with nothing to end the guard says so once"; fi

# 11. An OOM kill since the last pass.
cgroup 1000 500 0 0; standard_sessions
mkdir -p "${WORK}/pgdata"; echo $$ > "${WORK}/pgdata/postmaster.pid"
echo "sed -i 's/^oom_kill .*/oom_kill 2/' '${WORK}/cg/memory.events'" > "${WORK}/between"
log=$(guard 3)
rm -f "${WORK}/between"
check "an oom_kill increment is one ERROR line, with the postmaster running" [ "$(count "${log}" \
	'ERROR: event=oom_kill killed=2 from=0 to=2 used_pct=50 limit_mb=1000 postmaster=running note="crash recovery: every session ended"')" = 1 ]

# 12. psql failures are logged once a minute.
cgroup 1000 900 0 0; standard_sessions; touch "${WORK}/psql.fail"
log=$(guard 3)
rm -f "${WORK}/psql.fail"
if [ "$(count "${log}" "event=psql_failed used_pct=90 error=\"psql: error: connection to server failed: 'no' such socket\"")" = 1 ] && [ -z "$(terminated)" ]; then ok "a failing psql is logged once, with its error, and ends nothing"; else bad "a failing psql is logged once, with its error, and ends nothing"; fi

# 13. The idle rate cap.
cgroup 1000 870 0 0
sessions "601 90 client idle app a" "602 89 client idle app a" "603 88 client idle app a" "604 87 client idle app a" "605 86 client idle app a" \
	"606 85 client idle app a" "607 84 client idle app a" "608 83 client idle app a" "609 82 client idle app a" "610 81 client idle app a" \
	"611 80 client idle app a" "612 79 client idle app a"
log=$(guard 3 MEMORY_GUARD_IDLE_MAX_PER_MIN=7)
check "MEMORY_GUARD_IDLE_MAX_PER_MIN=7: 7 terminations over 3 passes" [ "$(terminated)" = "601 602 603 604 605 606 607 " ]
check "the cap is logged once" [ "$(count "${log}" 'WARN: event=rate_limited stage=idle max_per_min=7')" = 1 ]
cgroup 1000 930 0 0
log=$(guard 2 MEMORY_GUARD_IDLE_MAX_PER_MIN=3)
if [ "$(terminated | wc -w)" = 10 ] && [ "$(count "${log}" event=rate_limited)" = 0 ]; then ok "stage active is not capped"; else bad "stage active is not capped"; fi

# 14. Dry-run (the default) and the pause file.
cgroup 1000 970 0 0; standard_sessions
log=$(guard 1 MEMORY_GUARD_MODE=)
check "dry-run by default: no cancel or terminate statement" [ "$(statements)" = 0 ]
check "dry-run: the action lines say result=dry-run" has "${log}" "*event=action action=terminate stage=critical pid=201 *result=dry-run*"
cgroup 1000 870 0 0
log=$(guard 2 MEMORY_GUARD_MODE=)
check "dry-run keeps the pending state, so the next pass logs what enforce would do" [ "$(count "${log}" 'result=dry-run')" = 6 ]
touch "${WORK}/pause"
log=$(guard 1)
rm -f "${WORK}/pause"
if [ "$(statements)" = 0 ] && [ "$(count "${log}" 'result=paused')" = 5 ]; then ok "pause file: nothing sent even in enforce, lines say result=paused"; else bad "pause file: nothing sent even in enforce, lines say result=paused"; fi
# A pause file of another account (/tmp is writable by anyone) is ignored; stat is stubbed to say so.
cat > "${WORK}/bin/stat" <<'EOS'
#!/bin/sh
echo 4242
EOS
chmod +x "${WORK}/bin/stat"
touch "${WORK}/pause"
log=$(guard 1)
rm -f "${WORK}/pause" "${WORK}/bin/stat"
if [ "$(statements)" = 1 ] && [ "$(count "${log}" 'result=paused')" = 0 ]; then ok "a pause file owned by another account is ignored"; else bad "a pause file owned by another account is ignored"; fi

# 15. Settings.
# Backslashes in a logged value reach the log unchanged (dash's echo would read \c as "stop here").
log=$(guard 1 'MEMORY_GUARD_IDLE_BATCH=a\cb\n')
check "a backslash in a logged value is written as is" has "${log}" '*event=setting name=MEMORY_GUARD_IDLE_BATCH value="a\\cb\\n" used=5 reason="not an integer"*'

cgroup 1000 870 0 0; standard_sessions
log=$(guard 1 MEMORY_GUARD_EXCLUDE_USERS="backup,bad name,etl.job")
check "MEMORY_GUARD_EXCLUDE_USERS goes into the listing" has "$(grep 'LEFT JOIN pg_roles' "${WORK}/psql.log")" "*AND a.usename::text NOT IN ('backup', 'etl.job')*"
check "an invalid role name is dropped with a WARN" has "${log}" '*WARN: event=setting name=MEMORY_GUARD_EXCLUDE_USERS value="bad name" used=dropped reason=*'
log=$(guard 1 MEMORY_GUARD_IDLE_PERC=95 MEMORY_GUARD_ACTIVE_PERC=90)
check "thresholds out of order fall back to 85/92/96 with a WARN" \
	has "${log}" '*event=setting name=MEMORY_GUARD_IDLE_PERC,MEMORY_GUARD_ACTIVE_PERC,MEMORY_GUARD_CRITICAL_PERC value="95,90,96" used="85,92,96"*'
check "and the guard acts at 87% as with the defaults" [ "$(terminated)" = "101 102 103 104 105 " ]
guard 1 CONNECTION_MEMORY=65536 >/dev/null
check "MEMORY_GUARD_MIN_PRIVATE_MB follows CONNECTION_MEMORY (64 MB): only 101 and 102" [ "$(terminated)" = "101 102 " ]
guard 1 CONNECTION_MEMORY=65536 MEMORY_GUARD_MIN_PRIVATE_MB=50 >/dev/null
check "an explicit MEMORY_GUARD_MIN_PRIVATE_MB wins" [ "$(terminated)" = "101 102 103 104 " ]

# 16. Status line.
cgroup 1000 870 0 0; standard_sessions
echo "advance 1000; use 500" > "${WORK}/between"
log=$(guard 3 MEMORY_GUARD_STATUS_INTERVAL=1)
rm -f "${WORK}/between"
check "status every MEMORY_GUARD_STATUS_INTERVAL with peak and counts since the last line" \
	has "${log}" "*LOG: event=status used_pct=50 peak_pct=87 used_mb=500 limit_mb=1000 terminated=5 canceled=0*"

# 17. Self-throttling: a full pass over MEMORY_GUARD_TICK_BUDGET_MS doubles the interval up to
# MEMORY_GUARD_MAX_INTERVAL and the passes in between act from the last ranking.
cgroup 1000 870 0 0; standard_sessions
touch "${WORK}/psql.slow"
log=$(guard 1)
check "a slow pass is logged" has "${log}" "*WARN: event=slow_tick tick_ms=600 sessions=10 budget_ms=200 interval_ms=1000*"
check "a slow pass doubles the fast interval (500 -> 1000 ms)" [ "$(state mg_sleep_ms)" = 1000 ]
log=$(guard 3)
check "while throttled the next passes reuse the ranking: one listing in 3 passes" [ "$(listed)" = 1 ]
check "and still act from it, re-checked by the action statement" [ "$(terminated)" = "101 102 103 104 105 106 " ]
check "the slow line is throttled to once a minute" [ "$(count "${log}" event=slow_tick)" = 1 ]
echo "advance 5000" > "${WORK}/between"
guard 4 >/dev/null
if [ "$(listed)" = 4 ] && [ "$(state mg_sleep_ms)" = 5000 ]; then ok "a full scan every MEMORY_GUARD_MAX_INTERVAL; each slow one doubles up to 5 s"; else bad "a full scan every MEMORY_GUARD_MAX_INTERVAL; each slow one doubles up to 5 s"; fi
echo "touch '${WORK}/psql.slow'; advance 5000; rm -f '${WORK}/psql.slow'" > "${WORK}/between"
touch "${WORK}/psql.slow"
guard 2 >/dev/null
rm -f "${WORK}/between" "${WORK}/psql.slow"
if [ "$(state mg_sleep_ms)" = 500 ] && [ "$(state mg_throttle_ms)" = 0 ] && [ "$(listed)" = 2 ]; then ok "a full pass back under the budget ends the throttling (500 ms, fresh listing)"; else bad "a full pass back under the budget ends the throttling (500 ms, fresh listing)"; fi

# 17a. The query prefix carries no values: the listing masks dollar quotes, quoted identifiers
# holding a quote, E'' and plain string literals, comments and numbers in SQL, and only then cuts
# the text to MEMORY_GUARD_QUERY_CHARS. (A real server applies the patterns; see the simulation.)
cgroup 1000 870 0 0; standard_sessions
guard 1 >/dev/null
check "the listing masks before cutting the query prefix" \
	grep -qE "regexp_replace\(left\((regexp_replace\(){7}[[:space:]]*coalesce\(a.query, ''\)" "${WORK}/psql.log"
check "E'' strings with backslash escapes become ?" grep -qF "'[Ee]''(\\\\.|''''|[^''\\\\])*(''|\$)', '?', 'g'" "${WORK}/psql.log"
check "string literals become ?" grep -qF "'''(''''|[^''])*(''|\$)', '?', 'g'" "${WORK}/psql.log"
check "comments go" grep -qF "'/\*.*?(\*/|\$)', ' ', 'g'" "${WORK}/psql.log"
check "numeric literals become ?" grep -qF "'\m[0-9]+(\.[0-9]+)?\M', '?', 'g'" "${WORK}/psql.log"

# 17b. A slow pass spaces the next one by at least its own length (capped at the max interval),
# not only by twice the fast interval.
cgroup 1000 870 0 0; standard_sessions
echo 1.5 > "${WORK}/psql.slow"
guard 1 >/dev/null
check "a 3 s pass sets the interval to 3 s, not 1 s" [ "$(state mg_sleep_ms)" = 3000 ]
echo 9 > "${WORK}/psql.slow"
guard 1 >/dev/null
check "a pass longer than the max interval sets it to the max (5 s)" [ "$(state mg_sleep_ms)" = 5000 ]
rm -f "${WORK}/psql.slow"

# 17c. Stage idle lists idle client backends only; the other stages list every client backend and
# the parallel workers. A ranking listed in stage idle is not reused in a later stage.
cgroup 1000 870 0 0; standard_sessions
guard 1 >/dev/null
check "stage idle lists idle sessions only" grep -qE "a.state = 'idle'[[:space:]]+AND a.backend_type = 'client backend'" "${WORK}/psql.log"
check "stage idle lists no parallel worker" sh -c "! grep -q \"backend_type = 'parallel worker'\" '${WORK}/psql.log'"
cgroup 1000 930 0 0; standard_sessions
guard 1 >/dev/null
check "stage active lists every client backend and the parallel workers" grep -q "OR a.backend_type = 'parallel worker'" "${WORK}/psql.log"
cgroup 1000 870 0 0; standard_sessions
touch "${WORK}/psql.slow"
echo "use 930" > "${WORK}/between"
guard 2 >/dev/null
rm -f "${WORK}/between" "${WORK}/psql.slow"
check "a ranking listed in stage idle is not reused, throttled, in stage active" [ "$(listed)" = 2 ]

# 18. The loop: survives garbage, exits 0 on TERM, INT and HUP, and when off or unlimited.
loop() { # signal [VAR=value...]
	loop_signal=$1
	shift
	# Run in the foreground (a background job of a script ignores INT for good) and signalled by
	# timeout after 1.2 s; garbage is written into the cgroup half way.
	[ -d "${WORK}/cg" ] && (sleep 0.5; echo garbage > "${WORK}/cg/memory.current") &
	loop_start=$(date +%s%N)
	# shellcheck disable=SC2086  # ENVS is a list of assignments
	env ${ENVS} MEMORY_GUARD_INTERVAL=0.2 MEMORY_GUARD_FAST_INTERVAL=0.1 MEMORY_GUARD_CGROUP_RETRY=0 "$@" \
		timeout --preserve-status -s "${loop_signal}" 1.2 sh "${SCRIPTS}/psql_memory_guard.sh" 2> "${WORK}/loop.log"
	loop_status=$?
	wait
	if [ $(( ($(date +%s%N) - loop_start) / 1000000 )) -ge 1100 ]; then printf 'running '; fi
	echo "status ${loop_status}"
	cat "${WORK}/loop.log" >> "${WORK}/all.log"
}
for signal in TERM INT HUP
do
	cgroup 1000 500 0 0
	out=$(loop "${signal}")
	check "the loop keeps running on garbage readings and exits 0 on ${signal}" [ "${out}" = "running status 0" ]
done
cgroup 1000 500 0 0
loop TERM >/dev/null
start=$(grep 'event=start' "${WORK}/loop.log")
check "start line with mode, thresholds and lowered priority" has "${start}" \
	"*LOG: event=start mode=dry-run cgroup=v2 limit_mb=1000 used_pct=50 used_mb=500 interval=0.2 fast_interval=0.1 max_interval=* tick_budget_ms=200 idle_perc=85 active_perc=92 critical_perc=96 min_private_mb=16 oom_kills=0 nice=* ionice=*"
check "the guard lowered its own CPU priority (nice=10)" has "${start}" "* nice=10 *"
out=$(loop TERM MEMORY_GUARD_ENABLED=false)
if has "$(cat "${WORK}/loop.log")" "*LOG: event=disabled reason=off*" && [ "${out}" = "status 0" ]; then ok "MEMORY_GUARD_ENABLED=false exits 0 with event=disabled reason=off"; else bad "MEMORY_GUARD_ENABLED=false exits 0 with event=disabled reason=off"; fi
echo max > "${WORK}/cg/memory.max"
out=$(loop TERM)
if has "$(cat "${WORK}/loop.log")" "*LOG: event=disabled reason=unlimited*" && [ "${out}" = "status 0" ]; then ok "no memory limit: exits 0 with reason=unlimited"; else bad "no memory limit: exits 0 with reason=unlimited"; fi
rm -rf "${WORK}/cg"
out=$(loop TERM)
if has "$(cat "${WORK}/loop.log")" "*LOG: event=disabled reason=no_cgroup*" && [ "${out}" = "status 0" ]; then ok "no cgroup: exits 0 with reason=no_cgroup"; else bad "no cgroup: exits 0 with reason=no_cgroup"; fi
# Unreadable at first, readable 1 s later: the guard waits for it.
rm -rf "${WORK}/cg"
# shellcheck disable=SC2086  # ENVS is a list of assignments
env ${ENVS} MEMORY_GUARD_CGROUP_RETRY=5 sh "${SCRIPTS}/psql_memory_guard.sh" 2> "${WORK}/loop.log" &
pid=$!
sleep 1
cgroup 1000 500 0 0
sleep 1.5
kill -TERM "${pid}"; wait "${pid}"
check "an unreadable cgroup is retried before giving up" grep -q 'event=start' "${WORK}/loop.log"
cat "${WORK}/loop.log" >> "${WORK}/all.log"
cgroup 1000 500 0 0
loop TERM MEMORY_GUARD_IDLE_PERC=abc MEMORY_GUARD_FAST_INTERVAL=0 MEMORY_GUARD_MODE=on >/dev/null
check "bad settings fall back to their defaults with a WARN each" \
	[ "$(grep -c -e 'event=setting name=MEMORY_GUARD_IDLE_PERC value="abc" used=85 reason="not an integer"' \
		-e 'event=setting name=MEMORY_GUARD_FAST_INTERVAL value="0" used=0.5' -e 'event=setting name=MEMORY_GUARD_MODE value="on" used=dry-run' "${WORK}/loop.log")" = 3 ]

# 19. Faster passes under pressure.
cgroup 1000 900 0 0; sessions "601 4 client idle app tiny"; : > "${WORK}/psql.log"
# shellcheck disable=SC2086  # ENVS is a list of assignments
env ${ENVS} MEMORY_GUARD_INTERVAL=5 MEMORY_GUARD_FAST_INTERVAL=0.2 sh "${SCRIPTS}/psql_memory_guard.sh" 2>>"${WORK}/all.log" &
pid=$!; sleep 2; kill -TERM "${pid}"; wait "${pid}"
check "under pressure the guard checks every MEMORY_GUARD_FAST_INTERVAL ($(listed) passes in 2 s)" [ "$(listed)" -ge 4 ]

# 20. OOM targeting.
mkdir -p "${WORK}/fakeproc/self"; echo 0 > "${WORK}/fakeproc/self/oom_score_adj"
target() { # VAR=value...
	env MEMORY_CGROUP_DIR="${WORK}/cg" MEMORY_PROC_DIR="${WORK}/fakeproc" "$@" sh -c \
		". '${SCRIPTS}/psql_memory.sh'; psql_oom_target; echo \"rc=\$? file=\${PG_OOM_ADJUST_FILE:-} value=\${PG_OOM_ADJUST_VALUE:-}\"" 2>&1 | tee -a "${WORK}/all.log"
}
cgroup 1000 500 0 0 1
out=$(target)
check "OOM targeting exports PG_OOM_ADJUST_FILE and PG_OOM_ADJUST_VALUE=100 by default" has "${out}" "*rc=0 file=/proc/self/oom_score_adj value=100"
check "boot line with scores and the cgroup's limits" has "${out}" \
	'*LOG: event=oom_target state=on postmaster_oom_score_adj=0 child_oom_score_adj=100 cgroup=v2 memory_max=1048576000 memory_high=max swap_max=0 oom_group=1 note="only makes the victim deterministic; any kill is crash recovery"*'
check "memory.oom.group=1 is warned about" has "${out}" "*WARN: event=oom_group oom_group=1*"
cgroup 1000 500 0 0 0
out=$(target)
check "no oom_group line when it is 0" [ "$(count "${out}" event=oom_group)" = 0 ]
out=$(target OOM_TARGETING_ENABLED=false PG_OOM_ADJUST_FILE=x PG_OOM_ADJUST_VALUE=5)
check "OOM_TARGETING_ENABLED=false unsets both and says state=off" has "${out}" "*event=oom_target state=off postmaster_oom_score_adj=0 child_oom_score_adj=0 *rc=0 file= value="
out=$(target OOM_CHILD_SCORE_ADJ=-500)
check "a child score not above the postmaster's is warned about" has "${out}" "*WARN: event=oom_target_ineffective child_oom_score_adj=-500 postmaster_oom_score_adj=0*"
echo 300 > "${WORK}/fakeproc/self/oom_score_adj"
out=$(target)
check "also when the postmaster already starts above the children" has "${out}" "*event=oom_target_ineffective child_oom_score_adj=100 postmaster_oom_score_adj=300*"
out=$(target OOM_CHILD_SCORE_ADJ=5000)
check "OOM_CHILD_SCORE_ADJ is clamped to 1000 with a WARN" has "${out}" "*event=setting name=OOM_CHILD_SCORE_ADJ value=\"5000\" used=1000 reason=\"above the maximum\"*value=1000"
rm -rf "${WORK}/cg"
out=$(env MEMORY_CGROUP_DIR="${WORK}/cg" MEMORY_PROC_DIR="${WORK}/none" OOM_CHILD_SCORE_ADJ=x OOM_TARGETING_ENABLED=maybe sh -e -c \
	". '${SCRIPTS}/psql_memory.sh'; psql_oom_target; echo booted" 2>&1 | tee -a "${WORK}/all.log")
check "under errexit, with no cgroup, no /proc and bad settings, the boot goes on" has "${out}" "*state=on postmaster_oom_score_adj=unknown child_oom_score_adj=100 cgroup=none memory_max=unknown*booted"

# 21. Every line any test produced follows the format.
lines=$(grep -c 'MEMORY_GUARD:' "${WORK}/all.log")
badlines=$(grep 'MEMORY_GUARD:' "${WORK}/all.log" | grep -v -E \
	'^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Za-z0-9+-]+ \[[0-9]+\] MEMORY_GUARD: (LOG|WARN|ERROR): event=[a-z_]+( [a-z_]+=("[^"]*"|[^ "]*))*$')
check "all ${lines} lines: <date> [pid] MEMORY_GUARD: <LEVEL>: event=<name> key=value, strings quoted" [ -z "${badlines}" ]
[ -n "${badlines}" ] && printf '%s\n' "${badlines}" | head -n 5
check "no line over 4 kB" [ "$(awk 'length($0) > 4096' "${WORK}/all.log" | wc -l)" = 0 ]

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
