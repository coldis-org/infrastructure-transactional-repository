#!/bin/bash

# Tests for the memory budget of psql_tune_cmd.sh: connections and the other server processes (each
# one's own memory and its page tables for shared buffers) count against the container's memory,
# max_connections is lowered to what fits, a standby's floors (the primary's values) are kept, and
# work_mem is split over the sessions and parallel workers that can run at once. Runs on the host, with
# no docker: it stubs os_limits with the given CPUs and memory and takes every other default from
# the ENV block of the image's Dockerfile7.
#
#   bash src/test/infrastructure/repository/tune_test.sh
#
# Exits non-zero when any test fails.

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
REPOSITORY=${ROOT}/src/main/infrastructure/repository
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
pass=0; fail=0

ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# os_limits stub: CPUs, memory (MB) and disk (bytes) from the environment.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/os_limits" <<'EOF'
available_cpus() { AVAILABLE_CPUS=${TEST_CPUS}; }
available_memory() { AVAILABLE_MEMORY=${TEST_MEMORY_MB}; }
available_disk() { AVAILABLE_DISK=1099511627776; }
EOF
# The image defaults, as exports.
sed -n '/^ENV POSTGRES_ADMIN_USER/,/OVERWRITE_TUNED_ARGS/p' "${REPOSITORY}/Dockerfile7" \
	| sed 's/^ENV //; s/\\$//; s/^[[:space:]]*//' | grep '=' | sed 's/^/export /' > "${WORK}/env.sh"

# Tunes with the given memory (MB) and requested connections, plus any VAR=value overrides, and
# prints "<max_connections> <shared_buffers kB> <work_mem kB> <reserve %> <max_wal_senders>
# <maintenance_work_mem kB> <logical_decoding_work_mem kB> <warnings> <failed>", failed being the
# POSTGRES_TUNE_FAILED the init scripts stop on. Fails when the tuner does not finish within 20 s.
tune() { # memory-mb connections [VAR=value...]
	local memory=$1 connections=$2; shift 2
	(cd "${REPOSITORY}/script/psql" && PATH="${WORK}/bin:${PATH}" TEST_CPUS=16 TEST_MEMORY_MB=${memory} \
		PGDATA=/ timeout 20 sh -c ". '${WORK}/env.sh'; export MAX_CONNECTIONS=${connections} $*
		. ./psql_tune_cmd.sh; psql_tune_cmd postgres >/dev/null 2>'${WORK}/stderr'
		WARNINGS=\$(grep -c WARN '${WORK}/stderr')
		echo \"\${MAX_CONNECTIONS} \${SHARED_BUFFERS} \${WORK_MEM} \${ACTUAL_RESERVED_MEMORY_PERC} \${MAX_WAL_SENDERS} \${MAINTENANCE_WORK_MEM} \${LOGICAL_DECODING_WORK_MEM} \${WARNINGS} \${POSTGRES_TUNE_FAILED}\"")
}

# Tunes like tune() and prints the named variables, space separated (POSTGRES_TUNED_CMD last when
# asked for, since it holds spaces).
tunevars() { # memory-mb connections "VAR..." [VAR=value...]
	local memory=$1 connections=$2 vars=$3 out=""; shift 3
	for var in ${vars}; do out="${out} \${${var}}"; done
	(cd "${REPOSITORY}/script/psql" && PATH="${WORK}/bin:${PATH}" TEST_CPUS=16 TEST_MEMORY_MB=${memory} \
		PGDATA=/ timeout 20 sh -c ". '${WORK}/env.sh'; export MAX_CONNECTIONS=${connections} $*
		. ./psql_tune_cmd.sh; psql_tune_cmd postgres >/dev/null 2>'${WORK}/stderr'
		echo \"${out# }\"")
}

# True when every sized memory setting is at or above Postgres' minimum (kB), so the server starts.
valid() { # shared_buffers work_mem maintenance_work_mem logical_decoding_work_mem
	[ "${1:-0}" -ge 128 ] && [ "${2:-0}" -ge 64 ] && [ "${3:-0}" -ge 1024 ] && [ "${4:-0}" -ge 64 ]
}

# 1. A limit that fits is kept.
read -r conns _ _ reserve _ <<< "$(tune 262144 2500)"
[ "${conns}" = 2500 ] && ok "a limit that fits is kept (2500 at 256 GB)" || bad "2500 at 256 GB became ${conns}"
[ "${reserve:-0}" -ge 15 ] && ok "the reserve is kept (${reserve}%)" || bad "reserve ${reserve}% below 15%"

# 2. A limit that does not fit (8000 at 256 GB, which ran a production database out of memory) is
# lowered.
read -r conns _ _ reserve _ <<< "$(tune 262144 8000)"
[ -n "${conns}" ] && [ "${conns}" -lt 8000 ] && ok "8000 at 256 GB is lowered to ${conns}" || bad "8000 at 256 GB stayed ${conns}"
[ "${reserve:-0}" -ge 15 ] && ok "the reserve is kept with the lowered limit (${reserve}%)" || bad "reserve ${reserve}% below 15%"

# 3. More connections leave less shared buffers, since each one maps part of them.
read -r _ sb_few _ <<< "$(tune 262144 500)"
read -r _ sb_many _ <<< "$(tune 262144 4000)"
[ "${sb_many:-0}" -lt "${sb_few:-0}" ] && ok "shared buffers shrink with connections (${sb_few} -> ${sb_many} kB)" \
	|| bad "shared buffers did not shrink with connections (${sb_few} -> ${sb_many} kB)"

# 4. Huge pages, set explicitly, remove the page tables from the budget; an unknown value falls back
# to try.
read -r _ sb_huge _ <<< "$(tune 262144 4000 HUGE_PAGES=on)"
[ "${sb_huge:-0}" -gt "${sb_many:-0}" ] && ok "huge pages leave more shared buffers (${sb_many} -> ${sb_huge} kB)" \
	|| bad "huge pages did not leave more shared buffers (${sb_many} -> ${sb_huge} kB)"
read -r _ sb_bogus _ _ _ _ _ warnings _ <<< "$(tune 262144 4000 HUGE_PAGES=bogus)"
[ "${sb_bogus}" = "${sb_many}" ] && [ "${warnings:-0}" -ge 1 ] && ok "an unknown HUGE_PAGES falls back to try, with a warning" \
	|| bad "HUGE_PAGES=bogus: shared buffers ${sb_bogus} (try gives ${sb_many}), warnings ${warnings}"

# 5. A standby keeps its primary's limit even when it does not fit, and still gets settings Postgres
# accepts. The memory sizes are not multiples of 50 kB, so the budget loop cannot land on an exact
# remainder of zero by chance.
for case in "76800 8000" "65536 8000" "6144 700"; do
	read -r memory floor <<< "${case}"
	read -r conns sb wm _ _ mwm ldwm _ <<< "$(tune "${memory}" "${floor}" MAX_CONNECTIONS_MIN="${floor}")"
	if [ "${conns}" = "${floor}" ] && valid "${sb}" "${wm}" "${mwm}" "${ldwm}"
	then ok "the standby floor ${floor} at ${memory} MB is kept with valid settings (shared_buffers ${sb} kB)"
	else bad "standby floor ${floor} at ${memory} MB: connections '${conns}', shared_buffers '${sb}', work_mem '${wm}', maintenance '${mwm}', logical decoding '${ldwm}'"
	fi
done

# 6. Small memory (with 2 CPUs, as a container this small gets): from just above the fixed reserve
# (256 MB by default) up, the settings are ones Postgres accepts, the 10-connection floor taking a
# capped share rather than its full 16 MB each. The previous tuner gave 300 MB a work_mem of 30 kB
# (below the 64 kB minimum) by splitting it over all 300 connections. Below the reserve the budget
# cannot be met, and the tuner finishes and says so instead of looping.
for memory in 300 384 512 1024; do
	read -r conns sb wm _ _ mwm ldwm _ <<< "$(tune ${memory} 300 TEST_CPUS=2)"
	valid "${sb}" "${wm}" "${mwm}" "${ldwm}" && ok "${memory} MB gets valid settings (connections ${conns}, shared_buffers ${sb} kB)" \
		|| bad "${memory} MB: connections '${conns}', shared_buffers '${sb}', work_mem '${wm}', maintenance '${mwm}', logical decoding '${ldwm}'"
done
for memory in 256 128; do
	read -r conns _ _ _ _ _ _ warnings failed <<< "$(tune ${memory} 300)"
	[ -n "${conns}" ] && [ "${warnings:-0}" -ge 1 ] && [ "${failed}" = true ] \
		&& ok "${memory} MB finishes, warns and fails closed (the reserve cannot be kept)" \
		|| bad "${memory} MB: connections '${conns}', warnings '${warnings}', failed '${failed}'"
done

# 6b. A large standby whose primary forces a lock table that takes the reserve fails closed too:
# the last pass's settings are valid at this size, so only the flag stops the server.
read -r _ _ _ _ _ _ _ _ failed <<< "$(tune 32768 4874 MAX_CONNECTIONS_MIN=4874 MAX_LOCKS_PER_TRANSACTION_MIN=8000)"
[ "${failed}" = true ] && ok "a 32 GB standby whose primary's lock table takes the reserve fails closed" \
	|| bad "a 32 GB standby with a lock table over the reserve did not fail closed (failed '${failed}')"
read -r _ _ _ _ _ _ _ _ failed <<< "$(tune 262144 2500)"
[ "${failed}" = false ] && ok "a budget that fits does not fail" || bad "a budget that fits reported failed '${failed}'"

# 6c. Zero divisors are raised to 1 with a warning instead of stopping on an arithmetic error.
read -r conns _ wm _ _ _ _ warnings _ <<< "$(tune 4096 300 CONNECTION_MEMORY=0 WORK_MEM_OPERATIONS=0)"
[ -n "${conns}" ] && [ -n "${wm}" ] && [ "${warnings:-0}" -ge 1 ] && ok "CONNECTION_MEMORY=0 and WORK_MEM_OPERATIONS=0 are raised with a warning" \
	|| bad "zero divisors: connections '${conns}', work_mem '${wm}', warnings '${warnings}'"

# 7. WAL senders follow the requested limit, not the capped one: they do not count against
# max_connections, and replicas need them whatever the cap.
read -r conns _ _ _ senders _ <<< "$(tune 1024 300)"
[ "${conns}" -lt 300 ] && [ "${senders}" = 15 ] && ok "WAL senders stay at 5% of the requested 300 (${senders}) when connections are capped to ${conns}" \
	|| bad "WAL senders ${senders} with connections ${conns} (expected 15 with fewer than 300)"

# 8. work_mem is split over the connections expected to run a query at once (WORK_MEM_ACTIVE_PERC),
# not over all of them; out-of-range values are clamped with a warning, never divide by zero.
read -r wm_all <<< "$(tunevars 262144 2500 WORK_MEM)"
read -r wm_quarter <<< "$(tunevars 262144 2500 WORK_MEM WORK_MEM_ACTIVE_PERC=25)"
[ "${wm_quarter:-0}" -gt $(( ${wm_all:-0} * 2 )) ] && ok "WORK_MEM_ACTIVE_PERC=25 gives a larger work_mem (${wm_all} -> ${wm_quarter} kB)" \
	|| bad "WORK_MEM_ACTIVE_PERC=25: work_mem ${wm_all} -> ${wm_quarter} kB"
for perc in 0 500; do
	read -r wm conns <<< "$(tunevars 262144 2500 "WORK_MEM MAX_CONNECTIONS" WORK_MEM_ACTIVE_PERC=${perc})"
	warnings=$(grep -c WORK_MEM_ACTIVE_PERC "${WORK}/stderr")
	[ -n "${wm}" ] && [ "${wm}" -ge 64 ] && [ "${warnings}" -ge 1 ] && ok "WORK_MEM_ACTIVE_PERC=${perc} is clamped with a warning (work_mem ${wm} kB)" \
		|| bad "WORK_MEM_ACTIVE_PERC=${perc}: work_mem '${wm}', warnings ${warnings}"
done

# 9. Every parallel worker takes its own work_mem: more of them leave each a smaller one.
read -r wm_few <<< "$(tunevars 262144 2500 WORK_MEM MAX_PARALLEL_WORKERS_PERC=1)"
read -r wm_many <<< "$(tunevars 262144 2500 WORK_MEM MAX_PARALLEL_WORKERS_PERC=100 MAX_WORKER_PROCESSES=1000)"
[ "${wm_many:-0}" -lt "${wm_few:-0}" ] && ok "parallel workers take work_mem of their own (${wm_few} -> ${wm_many} kB)" \
	|| bad "parallel workers did not lower work_mem (${wm_few} -> ${wm_many} kB)"

# 10. Parallel workers per query are capped (MAX_PARALLEL_WORKERS_PER_GATHER_MAX, 4 by default):
# a percentage of 64 CPUs alone gives 38.
read -r gather <<< "$(tunevars 262144 2500 MAX_PARALLEL_WORKERS_PER_GATHER TEST_CPUS=64)"
[ "${gather}" = 4 ] && ok "64 CPUs get 4 parallel workers per gather" || bad "64 CPUs get ${gather} parallel workers per gather"
read -r gather <<< "$(tunevars 262144 2500 MAX_PARALLEL_WORKERS_PER_GATHER TEST_CPUS=64 MAX_PARALLEL_WORKERS_PER_GATHER_MAX=0)"
[ "${gather}" = 0 ] && ok "MAX_PARALLEL_WORKERS_PER_GATHER_MAX=0 turns parallel query off" || bad "MAX_PARALLEL_WORKERS_PER_GATHER_MAX=0 gave ${gather}"
read -r gather <<< "$(tunevars 1024 300 MAX_PARALLEL_WORKERS_PER_GATHER TEST_CPUS=2)"
[ "${gather}" = 1 ] && ok "2 CPUs keep 1 parallel worker per gather" || bad "2 CPUs get ${gather} parallel workers per gather"

# 11. The other server processes (background workers, autovacuum workers, WAL senders) cost memory
# like a connection: more of them leave room for fewer connections and less shared buffers, and
# the reserve is still kept.
read -r conns_few <<< "$(tunevars 4096 300 MAX_CONNECTIONS MAX_WORKER_PROCESSES=8)"
read -r conns_many <<< "$(tunevars 4096 300 MAX_CONNECTIONS MAX_WORKER_PROCESSES=40)"
[ "${conns_many:-0}" -lt "${conns_few:-0}" ] && ok "worker processes take room from connections (${conns_few} -> ${conns_many})" \
	|| bad "worker processes did not take room from connections (${conns_few} -> ${conns_many})"
read -r sb_few <<< "$(tunevars 262144 2500 SHARED_BUFFERS MAX_WORKER_PROCESSES=8)"
read -r sb_many reserve <<< "$(tunevars 262144 2500 "SHARED_BUFFERS ACTUAL_RESERVED_MEMORY_PERC" MAX_WORKER_PROCESSES=1000)"
[ "${sb_many:-0}" -lt "${sb_few:-0}" ] && [ "${reserve:-0}" -ge 15 ] && ok "1000 worker processes are budgeted (shared buffers ${sb_few} -> ${sb_many} kB, reserve ${reserve}%)" \
	|| bad "1000 worker processes: shared buffers ${sb_few} -> ${sb_many} kB, reserve ${reserve}%"
read -r sb_senders <<< "$(tunevars 262144 2500 SHARED_BUFFERS MAX_WORKER_PROCESSES=8 MAX_WAL_SENDERS_CONN_PERC=40)"
[ "${sb_senders:-0}" -lt "${sb_few:-0}" ] && ok "WAL senders are budgeted (shared buffers ${sb_few} -> ${sb_senders} kB)" \
	|| bad "WAL senders were not budgeted (shared buffers ${sb_few} -> ${sb_senders} kB)"

# 12. A standby's floors for worker processes and WAL senders (its primary's) are applied, and
# budgeted.
read -r workers senders failed <<< "$(tunevars 65536 300 "MAX_WORKER_PROCESSES MAX_WAL_SENDERS POSTGRES_TUNE_FAILED" MAX_WORKER_PROCESSES_MIN=200 MAX_WAL_SENDERS_MIN=40)"
[ "${workers}" = 200 ] && [ "${senders}" = 40 ] && [ "${failed}" = false ] && ok "standby floors: 200 worker processes and 40 WAL senders" \
	|| bad "standby floors: worker processes '${workers}', WAL senders '${senders}', failed '${failed}'"

# 13. Sessions idle in a transaction are ended after IDLE_IN_TRANSACTION_SESSION_TIMEOUT (30min by
# default).
cmd=$(tunevars 4096 300 POSTGRES_TUNED_CMD)
[[ "${cmd}" == *"-c idle_in_transaction_session_timeout=30min "* ]] && ok "idle_in_transaction_session_timeout is 30min by default" \
	|| bad "idle_in_transaction_session_timeout missing from the tuned command"
cmd=$(tunevars 4096 300 POSTGRES_TUNED_CMD IDLE_IN_TRANSACTION_SESSION_TIMEOUT=0)
[[ "${cmd}" == *"-c idle_in_transaction_session_timeout=0 "* ]] && ok "IDLE_IN_TRANSACTION_SESSION_TIMEOUT=0 is passed through" \
	|| bad "IDLE_IN_TRANSACTION_SESSION_TIMEOUT=0 not passed through"

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
