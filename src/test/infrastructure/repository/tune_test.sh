#!/bin/bash

# Tests for the memory budget of psql_tune_cmd.sh: connections (each one's own memory and its page
# tables for shared buffers) count against the container's memory, max_connections is lowered to
# what fits, and a standby's floor (the primary's max_connections) is kept. Runs on the host, with
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
# <maintenance_work_mem kB> <logical_decoding_work_mem kB> <warnings>". Fails when the tuner does
# not finish within 20 seconds.
tune() { # memory-mb connections [VAR=value...]
	local memory=$1 connections=$2; shift 2
	(cd "${REPOSITORY}/script/psql" && PATH="${WORK}/bin:${PATH}" TEST_CPUS=16 TEST_MEMORY_MB=${memory} \
		PGDATA=/ timeout 20 sh -c ". '${WORK}/env.sh'; export MAX_CONNECTIONS=${connections} $*
		. ./psql_tune_cmd.sh; psql_tune_cmd postgres >/dev/null 2>'${WORK}/stderr'
		WARNINGS=\$(grep -c WARN '${WORK}/stderr')
		echo \"\${MAX_CONNECTIONS} \${SHARED_BUFFERS} \${WORK_MEM} \${ACTUAL_RESERVED_MEMORY_PERC} \${MAX_WAL_SENDERS} \${MAINTENANCE_WORK_MEM} \${LOGICAL_DECODING_WORK_MEM} \${WARNINGS}\"")
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
read -r _ sb_bogus _ _ _ _ _ warnings <<< "$(tune 262144 4000 HUGE_PAGES=bogus)"
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

# 6. Small memory: 1 GB gets settings Postgres accepts; below the fixed reserve (256 MB by default)
# the budget cannot be met, and the tuner finishes and says so instead of looping.
read -r conns sb wm _ _ mwm ldwm _ <<< "$(tune 1024 300)"
valid "${sb}" "${wm}" "${mwm}" "${ldwm}" && ok "1024 MB gets valid settings (connections ${conns}, shared_buffers ${sb} kB)" \
	|| bad "1024 MB: shared_buffers '${sb}', work_mem '${wm}', maintenance '${mwm}', logical decoding '${ldwm}'"
for memory in 256 128; do
	read -r conns _ _ _ _ _ _ warnings <<< "$(tune ${memory} 300)"
	[ -n "${conns}" ] && [ "${warnings:-0}" -ge 1 ] && ok "${memory} MB finishes and warns that the reserve cannot be kept" \
		|| bad "${memory} MB: connections '${conns}', warnings '${warnings}'"
done

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
