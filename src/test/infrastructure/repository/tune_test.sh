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
# prints "<max_connections> <shared_buffers kB> <work_mem kB> <reserve %> <max_wal_senders>".
# Fails when the tuner does not finish within 20 seconds.
tune() { # memory-mb connections [VAR=value...]
	local memory=$1 connections=$2; shift 2
	(cd "${REPOSITORY}/script/psql" && PATH="${WORK}/bin:${PATH}" TEST_CPUS=16 TEST_MEMORY_MB=${memory} \
		PGDATA=/ timeout 20 sh -c ". '${WORK}/env.sh'; export MAX_CONNECTIONS=${connections} $*
		. ./psql_tune_cmd.sh; psql_tune_cmd postgres >/dev/null 2>&1
		echo \"\${MAX_CONNECTIONS} \${SHARED_BUFFERS} \${WORK_MEM} \${ACTUAL_RESERVED_MEMORY_PERC} \${MAX_WAL_SENDERS}\"")
}

# 1. A limit that fits is kept.
read -r conns _ _ reserve _ <<< "$(tune 262144 2500)"
[ "${conns}" = 2500 ] && ok "a limit that fits is kept (2500 at 256 GB)" || bad "2500 at 256 GB became ${conns}"
[ "${reserve:-0}" -ge 15 ] && ok "the reserve is kept (${reserve}%)" || bad "reserve ${reserve}% below 15%"

# 2. The limit that took the personal lending database down (8000 at 256 GB) is lowered.
read -r conns _ _ reserve _ <<< "$(tune 262144 8000)"
[ -n "${conns}" ] && [ "${conns}" -lt 8000 ] && ok "8000 at 256 GB is lowered to ${conns}" || bad "8000 at 256 GB stayed ${conns}"
[ "${reserve:-0}" -ge 15 ] && ok "the reserve is kept with the lowered limit (${reserve}%)" || bad "reserve ${reserve}% below 15%"

# 3. More connections leave less shared buffers, since each one maps part of them.
read -r _ sb_few _ <<< "$(tune 262144 500)"
read -r _ sb_many _ <<< "$(tune 262144 4000)"
[ "${sb_many:-0}" -lt "${sb_few:-0}" ] && ok "shared buffers shrink with connections (${sb_few} -> ${sb_many} kB)" \
	|| bad "shared buffers did not shrink with connections (${sb_few} -> ${sb_many} kB)"

# 4. Huge pages, set explicitly, remove the page tables from the budget.
read -r _ sb_huge _ <<< "$(tune 262144 4000 HUGE_PAGES=on)"
[ "${sb_huge:-0}" -gt "${sb_many:-0}" ] && ok "huge pages leave more shared buffers (${sb_many} -> ${sb_huge} kB)" \
	|| bad "huge pages did not leave more shared buffers (${sb_many} -> ${sb_huge} kB)"

# 5. A standby keeps its primary's limit even when it does not fit, and still finishes.
read -r conns _ <<< "$(tune 76800 8000 MAX_CONNECTIONS_MIN=8000)"
[ "${conns}" = 8000 ] && ok "the standby floor is kept (8000 at 75 GB)" || bad "the standby floor was not kept: ${conns}"

# 6. Small memory finishes, keeps a minimum of WAL senders and a valid work_mem.
for memory in 1024 256 128; do
	read -r conns _ wm _ senders <<< "$(tune ${memory} 300)"
	if [ -n "${conns}" ] && [ "${senders:-0}" -ge 2 ] && [ "${wm:-0}" -ge 64 ]
	then ok "${memory} MB finishes (connections ${conns}, wal senders ${senders}, work_mem ${wm} kB)"
	else bad "${memory} MB: connections '${conns}', wal senders '${senders}', work_mem '${wm}'"
	fi
done

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
