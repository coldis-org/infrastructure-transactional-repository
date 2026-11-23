#!/bin/sh

# Tests for the memory budget of psql_tune_cmd.sh: connections and the other server processes (each
# one's own memory and its page tables for shared buffers) count against the container's memory,
# max_connections is lowered to what fits (and never by the other server processes), a standby's
# floors (the primary's values) are kept, and work_mem is split over the sessions and parallel
# workers expected to run at once. Runs on the host, with no docker: it stubs os_limits with the
# given CPUs and memory and takes every other default from the ENV block of the image's Dockerfile7.
#
#   sh src/test/infrastructure/repository/tune_test.sh
#
# TUNE_SCRIPT=<path> runs the same cases against another copy of psql_tune_cmd.sh (an older
# release, for instance). Exits non-zero when any test fails.

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
REPOSITORY=${ROOT}/src/main/infrastructure/repository
TUNER=${TUNE_SCRIPT:-${REPOSITORY}/script/psql/psql_tune_cmd.sh}
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

# Tunes with the given memory (MB) and requested connections (16 CPUs unless TEST_CPUS is given),
# plus any VAR=value overrides, and prints the named variables space separated, "-" for an empty
# one (POSTGRES_TUNED_CMD last when asked for, since it holds spaces). WARNINGS is the count of
# warning lines; the warnings themselves are left in ${WORK}/stderr. Prints nothing when the tuner
# does not finish within 20 s.
tunevars() { # memory-mb connections "VAR..." [VAR=value...]
	tv_memory=$1; tv_connections=$2; tv_out=""
	for tv_var in $3; do tv_out="${tv_out} \${${tv_var}:--}"; done
	shift 3
	(cd "${REPOSITORY}/script/psql" && PATH="${WORK}/bin:${PATH}" TEST_CPUS=16 TEST_MEMORY_MB=${tv_memory} \
		PGDATA=/ timeout 20 sh -c ". '${WORK}/env.sh'; export MAX_CONNECTIONS=${tv_connections} $*
		. '${TUNER}'; psql_tune_cmd postgres >/dev/null 2>'${WORK}/stderr'
		WARNINGS=\$(grep -c WARN '${WORK}/stderr')
		echo \"${tv_out# }\"")
}

# Prints "<max_connections> <shared_buffers kB> <work_mem kB> <reserve %> <max_wal_senders>
# <maintenance_work_mem kB> <logical_decoding_work_mem kB> <warnings> <failed>", failed being
# POSTGRES_TUNE_FAILED, which no memory shortfall sets any longer.
tune() { # memory-mb connections [VAR=value...]
	t_memory=$1; t_connections=$2; shift 2
	tunevars "${t_memory}" "${t_connections}" "MAX_CONNECTIONS SHARED_BUFFERS WORK_MEM ACTUAL_RESERVED_MEMORY_PERC MAX_WAL_SENDERS MAINTENANCE_WORK_MEM LOGICAL_DECODING_WORK_MEM WARNINGS POSTGRES_TUNE_FAILED" "$@"
}

# True when every sized memory setting is at or above Postgres' minimum (kB), so the server starts.
valid() { # shared_buffers work_mem maintenance_work_mem logical_decoding_work_mem
	is_number "$1" && is_number "$2" && is_number "$3" && is_number "$4" \
		&& [ "$1" -ge 128 ] && [ "$2" -ge 64 ] && [ "$3" -ge 1024 ] && [ "$4" -ge 64 ]
}

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

# True when the warnings of the last run hold the given text.
warned() { grep -q "$1" "${WORK}/stderr"; }

# 1. A limit that fits is kept.
# shellcheck disable=SC2046  # the fields are split on purpose
set -- $(tune 262144 2500)
[ "$1" = 2500 ] && ok "a limit that fits is kept (2500 at 256 GB)" || bad "2500 at 256 GB became $1"
is_number "$4" && [ "$4" -ge 15 ] && ok "the reserve is kept ($4%)" || bad "reserve $4% below 15%"

# 2. A limit far beyond what the memory holds (8000 at 256 GB) is lowered.
# shellcheck disable=SC2046
set -- $(tune 262144 8000)
is_number "$1" && [ "$1" -lt 8000 ] && ok "8000 at 256 GB is lowered to $1" || bad "8000 at 256 GB stayed $1"
is_number "$4" && [ "$4" -ge 15 ] && ok "the reserve is kept with the lowered limit ($4%)" || bad "reserve $4% below 15%"

# 3. More connections leave less shared buffers, since each one maps part of them.
# shellcheck disable=SC2046
set -- $(tune 262144 500); sb_few=$2
# shellcheck disable=SC2046
set -- $(tune 262144 4000); sb_many=$2
[ "${sb_many:-0}" -lt "${sb_few:-0}" ] && ok "shared buffers shrink with connections (${sb_few} -> ${sb_many} kB)" \
	|| bad "shared buffers did not shrink with connections (${sb_few} -> ${sb_many} kB)"

# 4. Huge pages, set explicitly, remove the page tables from the budget; an unknown value falls back
# to try.
# shellcheck disable=SC2046
set -- $(tune 262144 4000 HUGE_PAGES=on); sb_huge=$2
[ "${sb_huge:-0}" -gt "${sb_many:-0}" ] && ok "huge pages leave more shared buffers (${sb_many} -> ${sb_huge} kB)" \
	|| bad "huge pages did not leave more shared buffers (${sb_many} -> ${sb_huge} kB)"
# shellcheck disable=SC2046
set -- $(tune 262144 4000 HUGE_PAGES=bogus)
[ "$2" = "${sb_many}" ] && [ "${8:-0}" -ge 1 ] && ok "an unknown HUGE_PAGES falls back to try, with a warning" \
	|| bad "HUGE_PAGES=bogus: shared buffers $2 (try gives ${sb_many}), warnings $8"

# 5. A standby keeps its primary's limit even when it does not fit, and still gets settings Postgres
# accepts. The memory sizes are not multiples of 50 kB, so the budget loop cannot land on an exact
# remainder of zero by chance.
for case in "76800 8000" "65536 8000" "6144 700"; do
	# shellcheck disable=SC2086
	set -- ${case}; memory=$1; floor=$2
	# shellcheck disable=SC2046
	set -- $(tune "${memory}" "${floor}" MAX_CONNECTIONS_MIN="${floor}")
	if [ "$1" = "${floor}" ] && valid "$2" "$3" "$6" "$7"
	then ok "the standby floor ${floor} at ${memory} MB is kept with valid settings (shared_buffers $2 kB)"
	else bad "standby floor ${floor} at ${memory} MB: connections '$1', shared_buffers '$2', work_mem '$3', maintenance '$6', logical decoding '$7'"
	fi
done

# 6. Small memory (with 2 CPUs, as a container this small gets): from just above the fixed reserve
# (256 MB by default) up, the settings are ones Postgres accepts and the reserve is kept, the
# 10-connection floor taking a capped share rather than its full 16 MB each, and the other server
# processes their capped share. The 7.2 tuner gave 300 MB a work_mem of 30 kB (below the 64 kB
# minimum) by splitting it over all 300 connections.
for memory in 300 384 512 1024; do
	# shellcheck disable=SC2046
	set -- $(tune ${memory} 300 TEST_CPUS=2)
	valid "$2" "$3" "$6" "$7" && [ "$9" = false ] && ok "${memory} MB gets valid settings (connections $1, shared_buffers $2 kB)" \
		|| bad "${memory} MB: connections '$1', shared_buffers '$2', work_mem '$3', maintenance '$6', logical decoding '$7', failed '$9'"
done
# Below the reserve itself the budget cannot be met: the server still starts (7.3.0 refused to),
# with the connections at their floor of 10, settings Postgres accepts, and one WARN that says how
# much reserve is left.
for memory in 256 128; do
	# shellcheck disable=SC2046
	set -- $(tune ${memory} 300)
	if [ "$1" = 10 ] && valid "$2" "$3" "$6" "$7" && [ "$9" != true ] && warned "NOT ENOUGH MEMORY: starting without the reserve. Requested 300 connections, applied 10"
	then ok "${memory} MB starts with 10 connections, valid settings and a WARN (the reserve cannot be kept)"
	else bad "${memory} MB: connections '$1', shared_buffers '$2', work_mem '$3', maintenance '$6', logical decoding '$7', failed '$9'"
	fi
done

# 6b. A large standby whose primary forces a lock table that takes the reserve starts too: its
# connections and locks stay at the primary's (a standby cannot go below them), everything else
# shrinks to Postgres' minimums, and the WARN names the standby floors.
# shellcheck disable=SC2046
set -- $(tune 32768 4874 MAX_CONNECTIONS_MIN=4874 MAX_LOCKS_PER_TRANSACTION_MIN=8000)
if [ "$1" = 4874 ] && valid "$2" "$3" "$6" "$7" && [ "$9" != true ] && warned "NOT ENOUGH MEMORY" && warned "As a standby it keeps its primary's"
then ok "a 32 GB standby whose primary's lock table takes the reserve starts at the primary's 4874 connections, with a WARN"
else bad "32 GB standby with a lock table over the reserve: connections '$1', shared_buffers '$2', work_mem '$3', failed '$9'"
fi
# shellcheck disable=SC2046
set -- $(tunevars 32768 4874 "MAX_LOCKS_PER_TRANSACTION" MAX_CONNECTIONS_MIN=4874 MAX_LOCKS_PER_TRANSACTION_MIN=8000)
[ "$1" = 8000 ] && ok "that standby keeps the primary's max_locks_per_transaction (8000)" \
	|| bad "that standby's max_locks_per_transaction is '$1', below the primary's 8000"
# shellcheck disable=SC2046
set -- $(tune 262144 2500)
[ "$9" = false ] && ! warned "NOT ENOUGH MEMORY" && ok "a budget that fits neither fails nor warns of a shortfall" \
	|| bad "a budget that fits reported failed '$9' or a shortfall"

# 6d. A primary whose fixed costs (here a lock table forced large) leave too little for the rest
# lowers max_connections below what its memory would otherwise hold, rather than shrink shared
# buffers to nothing, and keeps the reserve.
# shellcheck disable=SC2046
set -- $(tunevars 4096 300 "MAX_CONNECTIONS SHARED_BUFFERS ACTUAL_RESERVED_MEMORY_PERC MAX_LOCKS_PER_TRANSACTION" TEST_CPUS=4 \
	MAX_LOCKS_PER_TRANSACTION_MIN=20000 MAX_LOCKS_PER_TRANSACTION_MAX=20000)
if is_number "$1" && [ "$1" -lt 76 ] && [ "$1" -ge 10 ] && [ "$2" -gt 128 ] && [ "$3" -ge 15 ] && [ "$4" = 20000 ] && warned "lowered max_connections to $1 to keep the reserve"
then ok "a lock table too large for 76 connections at 4 GB lowers them to $1 and keeps the reserve ($3%)"
else bad "4 GB with 20000 locks per transaction: connections '$1', shared_buffers '$2', reserve '$3'%, locks '$4'"
fi

# 6e. A 1 GB standby of a 2 GB primary (both 2 CPUs) inherits the primary's max_connections,
# max_locks_per_transaction, max_worker_processes and max_wal_senders (its init sets them as
# floors, from pg_control) and starts with valid settings, keeping those values. Also with the
# 8388 locks per transaction and 10 connections a 2 GB primary got from the first draft of this
# release, which lowered its connections for the other server processes.
# shellcheck disable=SC2046
set -- $(tunevars 2048 300 "MAX_CONNECTIONS MAX_LOCKS_PER_TRANSACTION MAX_WORKER_PROCESSES MAX_WAL_SENDERS" TEST_CPUS=2)
for primary in "$1 $2 $3 $4" "10 8388 $3 $4"; do
	# shellcheck disable=SC2086
	set -- ${primary}
	p_connections=$1; p_locks=$2; p_workers=$3; p_senders=$4
	# shellcheck disable=SC2046
	set -- $(tunevars 1024 300 "MAX_CONNECTIONS MAX_LOCKS_PER_TRANSACTION MAX_WORKER_PROCESSES MAX_WAL_SENDERS SHARED_BUFFERS WORK_MEM MAINTENANCE_WORK_MEM LOGICAL_DECODING_WORK_MEM POSTGRES_TUNE_FAILED" TEST_CPUS=2 \
		MAX_CONNECTIONS_MIN="${p_connections}" MAX_LOCKS_PER_TRANSACTION_MIN="${p_locks}" MAX_WORKER_PROCESSES_MIN="${p_workers}" MAX_WAL_SENDERS_MIN="${p_senders}")
	if [ "$1" -ge "${p_connections}" ] && [ "$2" -ge "${p_locks}" ] && [ "$3" -ge "${p_workers}" ] && [ "$4" -ge "${p_senders}" ] 2>/dev/null \
		&& valid "$5" "$6" "$7" "$8" && [ "$9" != true ]
	then ok "a 1 GB standby of a 2 GB primary (${p_connections} connections, ${p_locks} locks) starts with the primary's floors and valid settings"
	else bad "1 GB standby of a 2 GB primary (${p_connections} connections, ${p_locks} locks): got '$*'"
	fi
done

# 6c. Zero divisors are raised to 1 with a warning instead of stopping on an arithmetic error.
# shellcheck disable=SC2046
set -- $(tune 4096 300 CONNECTION_MEMORY=0 WORK_MEM_OPERATIONS=0)
is_number "$1" && is_number "$3" && [ "${8:-0}" -ge 1 ] && ok "CONNECTION_MEMORY=0 and WORK_MEM_OPERATIONS=0 are raised with a warning" \
	|| bad "zero divisors: connections '$1', work_mem '$3', warnings '$8'"

# 7. WAL senders follow the requested limit, not the capped one: they do not count against
# max_connections, and replicas need them whatever the cap.
# shellcheck disable=SC2046
set -- $(tune 1024 300)
is_number "$1" && [ "$1" -lt 300 ] && [ "$5" = 15 ] && ok "WAL senders stay at 5% of the requested 300 ($5) when connections are capped to $1" \
	|| bad "WAL senders $5 with connections $1 (expected 15 with fewer than 300)"

# 8. work_mem is split over the connections expected to run a query at once (WORK_MEM_ACTIVE_PERC,
# 65 by default when the image sets none), not over all of them.
wm_all=$(tunevars 262144 2500 WORK_MEM WORK_MEM_ACTIVE_PERC=100)
wm_quarter=$(tunevars 262144 2500 WORK_MEM WORK_MEM_ACTIVE_PERC=25)
is_number "${wm_quarter}" && [ "${wm_quarter}" -gt $(( ${wm_all:-0} * 2 )) ] && ok "WORK_MEM_ACTIVE_PERC=25 gives a larger work_mem (${wm_all} -> ${wm_quarter} kB)" \
	|| bad "WORK_MEM_ACTIVE_PERC=25: work_mem ${wm_all} -> ${wm_quarter} kB"
# shellcheck disable=SC2046
set -- $(tunevars 262144 2500 "WORK_MEM_ACTIVE_PERC WORK_MEM" WORK_MEM_ACTIVE_PERC=)
[ "$1" = 65 ] && is_number "$2" && [ "$2" -gt "${wm_all:-0}" ] && ok "WORK_MEM_ACTIVE_PERC is 65 when unset (work_mem ${wm_all} -> $2 kB)" \
	|| bad "unset WORK_MEM_ACTIVE_PERC: '$1', work_mem '$2' (100 gives ${wm_all})"

# 8b. Out of range, it is clamped to 10..100 with a warning (the floor keeps the over-commit at ten
# times); anything but a number falls back to 65. Never a division by zero.
for case in "0 10" "5 10" "500 100" "abc 65"; do
	# shellcheck disable=SC2086
	set -- ${case}; perc=$1; expected=$2
	# shellcheck disable=SC2046
	set -- $(tunevars 262144 2500 "WORK_MEM_ACTIVE_PERC WORK_MEM" WORK_MEM_ACTIVE_PERC=${perc})
	[ "$1" = "${expected}" ] && is_number "$2" && [ "$2" -ge 64 ] && warned WORK_MEM_ACTIVE_PERC=${perc} \
		&& ok "WORK_MEM_ACTIVE_PERC=${perc} becomes ${expected} with a warning (work_mem $2 kB)" \
		|| bad "WORK_MEM_ACTIVE_PERC=${perc}: '$1' (expected ${expected}), work_mem '$2', warnings: $(cat "${WORK}/stderr")"
done

# 8c. Below 100 the boot says how far work memory can go when every connection and parallel worker
# sorts at once; at 100 it does not.
tunevars 262144 2500 WORK_MEM WORK_MEM_ACTIVE_PERC=50 >/dev/null
warned "work memory can reach" && ok "WORK_MEM_ACTIVE_PERC=50 logs the over-commit at boot" \
	|| bad "WORK_MEM_ACTIVE_PERC=50 logged no over-commit line"
tunevars 262144 2500 WORK_MEM WORK_MEM_ACTIVE_PERC=100 >/dev/null
warned "work memory can reach" && bad "WORK_MEM_ACTIVE_PERC=100 logged an over-commit line" \
	|| ok "WORK_MEM_ACTIVE_PERC=100 logs no over-commit"

# 8d. WORK_MEM_MAX caps work_mem (kB); empty means no cap, below the 64 kB minimum it is raised.
wm=$(tunevars 262144 2500 WORK_MEM WORK_MEM_MAX=1024)
[ "${wm}" = 1024 ] && ok "WORK_MEM_MAX=1024 caps work_mem" || bad "WORK_MEM_MAX=1024 gave work_mem ${wm}"
wm_nocap=$(tunevars 262144 2500 WORK_MEM WORK_MEM_MAX=)
wm_default=$(tunevars 262144 2500 WORK_MEM)
is_number "${wm_nocap}" && [ "${wm_nocap}" -gt 1024 ] && [ "${wm_nocap}" = "${wm_default}" ] && ok "an empty WORK_MEM_MAX caps nothing (${wm_nocap} kB)" \
	|| bad "empty WORK_MEM_MAX: work_mem '${wm_nocap}' (default '${wm_default}')"
wm=$(tunevars 262144 2500 WORK_MEM WORK_MEM_MAX=10)
[ "${wm}" = 64 ] && warned WORK_MEM_MAX && ok "WORK_MEM_MAX=10 is raised to 64 with a warning" \
	|| bad "WORK_MEM_MAX=10 gave work_mem ${wm}"

# 9. Every parallel worker takes its own work_mem: more of them leave each a smaller one.
wm_few=$(tunevars 262144 2500 WORK_MEM MAX_PARALLEL_WORKERS_PERC=1)
wm_many=$(tunevars 262144 2500 WORK_MEM MAX_PARALLEL_WORKERS_PERC=100 MAX_WORKER_PROCESSES=1000)
[ "${wm_many:-0}" -lt "${wm_few:-0}" ] && ok "parallel workers take work_mem of their own (${wm_few} -> ${wm_many} kB)" \
	|| bad "parallel workers did not lower work_mem (${wm_few} -> ${wm_many} kB)"

# 10. Parallel workers per query are capped (MAX_PARALLEL_WORKERS_PER_GATHER_MAX, 2 by default,
# whatever the memory): a percentage of 64 CPUs alone gives 38. A value given wins, above 2 too.
gather=$(tunevars 262144 2500 MAX_PARALLEL_WORKERS_PER_GATHER TEST_CPUS=64 MAX_PARALLEL_WORKERS_PER_GATHER_MAX=4)
[ "${gather}" = 4 ] && ok "64 CPUs get 4 parallel workers per gather with a cap of 4" || bad "64 CPUs get ${gather} parallel workers per gather with a cap of 4"
for memory in 4096 65536 262144 360448; do
	gather=$(tunevars "${memory}" 2500 MAX_PARALLEL_WORKERS_PER_GATHER TEST_CPUS=64 MAX_PARALLEL_WORKERS_PER_GATHER_MAX=)
	[ "${gather}" = 2 ] && ok "unset MAX_PARALLEL_WORKERS_PER_GATHER_MAX gives ${memory} MB with 64 CPUs 2 per gather" \
		|| bad "unset MAX_PARALLEL_WORKERS_PER_GATHER_MAX gives ${memory} MB ${gather} per gather (expected 2)"
done
gather=$(tunevars 360448 5500 MAX_PARALLEL_WORKERS_PER_GATHER TEST_CPUS=62 MAX_PARALLEL_WORKERS_PER_GATHER_MAX=8)
[ "${gather}" = 8 ] && ok "MAX_PARALLEL_WORKERS_PER_GATHER_MAX=8 is honoured at 352 GiB / 62 CPUs" || bad "MAX_PARALLEL_WORKERS_PER_GATHER_MAX=8 at 352 GiB gave ${gather}"
gather=$(tunevars 262144 2500 MAX_PARALLEL_WORKERS_PER_GATHER TEST_CPUS=64 MAX_PARALLEL_WORKERS_PER_GATHER_MAX=0)
[ "${gather}" = 0 ] && ok "MAX_PARALLEL_WORKERS_PER_GATHER_MAX=0 turns parallel query off" || bad "MAX_PARALLEL_WORKERS_PER_GATHER_MAX=0 gave ${gather}"
gather=$(tunevars 262144 2500 MAX_PARALLEL_WORKERS_PER_GATHER TEST_CPUS=64 MAX_PARALLEL_WORKERS_PER_GATHER_MAX=x)
[ "${gather}" = 2 ] && warned MAX_PARALLEL_WORKERS_PER_GATHER_MAX && ok "MAX_PARALLEL_WORKERS_PER_GATHER_MAX=x falls back to 2 with a warning" \
	|| bad "MAX_PARALLEL_WORKERS_PER_GATHER_MAX=x gave ${gather}"
# The work_mem budget counts every parallel worker that can run (max_parallel_workers) whatever the
# number per gather, so a higher cap leaves work_mem as it was.
wm_cap2=$(tunevars 360448 5500 WORK_MEM TEST_CPUS=62 MAX_PARALLEL_WORKERS_PER_GATHER_MAX=2)
wm_cap8=$(tunevars 360448 5500 WORK_MEM TEST_CPUS=62 MAX_PARALLEL_WORKERS_PER_GATHER_MAX=8)
is_number "${wm_cap8}" && [ "${wm_cap8}" = "${wm_cap2}" ] && ok "the per-gather cap leaves the work_mem budget as it was (${wm_cap8} kB)" \
	|| bad "the per-gather cap moved work_mem (${wm_cap2} -> ${wm_cap8} kB)"
gather=$(tunevars 1024 300 MAX_PARALLEL_WORKERS_PER_GATHER TEST_CPUS=2)
[ "${gather}" = 1 ] && ok "2 CPUs keep 1 parallel worker per gather" || bad "2 CPUs get ${gather} parallel workers per gather"

# 11. The other server processes (background workers, autovacuum workers, WAL senders, auxiliary
# processes) are budgeted in a term of their own: more of them leave less shared buffers and the
# reserve is still kept, but they never take room from connections.
conns_few=$(tunevars 4096 300 MAX_CONNECTIONS MAX_WORKER_PROCESSES=8)
conns_many=$(tunevars 4096 300 MAX_CONNECTIONS MAX_WORKER_PROCESSES=40)
is_number "${conns_few}" && [ "${conns_many}" = "${conns_few}" ] && ok "worker processes take no room from connections (${conns_few} with 8 or 40)" \
	|| bad "worker processes changed connections (${conns_few} -> ${conns_many})"
sb_few=$(tunevars 262144 2500 SHARED_BUFFERS MAX_WORKER_PROCESSES=8)
# shellcheck disable=SC2046
set -- $(tunevars 262144 2500 "SHARED_BUFFERS ACTUAL_RESERVED_MEMORY_PERC" MAX_WORKER_PROCESSES=1000)
[ "${1:-0}" -lt "${sb_few:-0}" ] && [ "${2:-0}" -ge 15 ] && ok "1000 worker processes are budgeted (shared buffers ${sb_few} -> $1 kB, reserve $2%)" \
	|| bad "1000 worker processes: shared buffers ${sb_few} -> $1 kB, reserve $2%"
sb_senders=$(tunevars 262144 2500 SHARED_BUFFERS MAX_WORKER_PROCESSES=8 MAX_WAL_SENDERS_CONN_PERC=40)
[ "${sb_senders:-0}" -lt "${sb_few:-0}" ] && ok "WAL senders are budgeted (shared buffers ${sb_few} -> ${sb_senders} kB)" \
	|| bad "WAL senders were not budgeted (shared buffers ${sb_few} -> ${sb_senders} kB)"
# shellcheck disable=SC2046
set -- $(tunevars 1024 300 "TOTAL_SERVER_PROCESSES_MEMORY SERVER_PROCESSES_MEMORY_SHARE SERVER_PROCESSES" TEST_CPUS=2)
is_number "$1" && [ "$1" -gt 0 ] && [ "$1" = "$2" ] && ok "a small container budgets its $3 server processes up to their share ($1 kB)" \
	|| bad "1 GB: server processes' memory '$1', share '$2', processes '$3'"

# 11b. Regression guard: the server processes' term does not lower max_connections against 7.3.0,
# whose values (300 requested, the image defaults) were measured with this harness on its script.
for case in "1024 2 16" "2048 2 38" "4096 4 76"; do
	# shellcheck disable=SC2086
	set -- ${case}; memory=$1; cpus=$2; previous=$3
	# shellcheck disable=SC2046
	set -- $(tunevars "${memory}" 300 "MAX_CONNECTIONS POSTGRES_TUNE_FAILED" TEST_CPUS="${cpus}")
	is_number "$1" && [ "$1" -ge "${previous}" ] && [ "$2" = false ] \
		&& ok "${memory} MB with ${cpus} CPUs keeps max_connections at $1 (7.3.0: ${previous})" \
		|| bad "${memory} MB with ${cpus} CPUs: max_connections '$1' below 7.3.0's ${previous} (failed '$2')"
done

# 11c. Lock table rows are counted for the other server processes too. PostgreSQL 18 sizes them
# over autovacuum_worker_slots (16) rather than autovacuum_max_workers, and runs 3 I/O workers.
# shellcheck disable=SC2046
set -- $(tunevars 4096 300 "SERVER_LOCK_SLOTS SERVER_PROCESSES" TEST_CPUS=2 PG_MAJOR=17); slots17=$1; procs17=$2
# shellcheck disable=SC2046
set -- $(tunevars 4096 300 "SERVER_LOCK_SLOTS SERVER_PROCESSES AUTOVACUUM_MAX_WORKERS" TEST_CPUS=2 PG_MAJOR=18)
is_number "${slots17}" && [ "$1" = $(( slots17 - $3 + 16 )) ] && [ "$2" = $(( procs17 + 3 )) ] \
	&& ok "PostgreSQL 18 counts 16 autovacuum lock slots and 3 I/O workers (slots ${slots17} -> $1, processes ${procs17} -> $2)" \
	|| bad "PostgreSQL 18: lock slots ${slots17} -> '$1', processes ${procs17} -> '$2' (autovacuum workers '$3')"

# 12. A standby's floors for worker processes and WAL senders (its primary's) are applied, and
# budgeted, with the reserve kept.
# shellcheck disable=SC2046
set -- $(tunevars 65536 300 "MAX_WORKER_PROCESSES MAX_WAL_SENDERS POSTGRES_TUNE_FAILED ACTUAL_RESERVED_MEMORY_PERC" MAX_WORKER_PROCESSES_MIN=200 MAX_WAL_SENDERS_MIN=40)
[ "$1" = 200 ] && [ "$2" = 40 ] && [ "$3" = false ] && is_number "$4" && [ "$4" -ge 15 ] \
	&& ok "standby floors: 200 worker processes and 40 WAL senders, reserve $4%" \
	|| bad "standby floors: worker processes '$1', WAL senders '$2', failed '$3', reserve '$4'"
# shellcheck disable=SC2046
set -- $(tunevars 65536 300 "MAX_WORKER_PROCESSES MAX_WAL_SENDERS" MAX_WORKER_PROCESSES_MIN= MAX_WAL_SENDERS_MIN=)
plain_workers=$1; plain_senders=$2
# shellcheck disable=SC2046
set -- $(tunevars 65536 300 "MAX_WORKER_PROCESSES MAX_WAL_SENDERS" MAX_WORKER_PROCESSES_MIN=1 MAX_WAL_SENDERS_MIN=1)
[ "$1" = "${plain_workers}" ] && [ "$2" = "${plain_senders}" ] && is_number "$1" \
	&& ok "floors below the tuned values change nothing (${plain_workers} workers, ${plain_senders} WAL senders)" \
	|| bad "low floors: workers '$1' (tuned '${plain_workers}'), WAL senders '$2' (tuned '${plain_senders}')"

# 13. Sessions idle in a transaction are ended after IDLE_IN_TRANSACTION_SESSION_TIMEOUT (30min by
# default); a value the server would refuse falls back to 30min with a warning.
cmd=$(tunevars 4096 300 POSTGRES_TUNED_CMD IDLE_IN_TRANSACTION_SESSION_TIMEOUT=)
case "${cmd}" in
	*"-c idle_in_transaction_session_timeout=30min "*) ok "idle_in_transaction_session_timeout is 30min by default" ;;
	*) bad "idle_in_transaction_session_timeout=30min missing from the tuned command" ;;
esac
for timeout in 0 250ms 2h 45 24d 2147483647; do
	cmd=$(tunevars 4096 300 POSTGRES_TUNED_CMD IDLE_IN_TRANSACTION_SESSION_TIMEOUT=${timeout})
	case "${cmd}" in
		*"-c idle_in_transaction_session_timeout=${timeout} "*) ok "IDLE_IN_TRANSACTION_SESSION_TIMEOUT=${timeout} is passed through" ;;
		*) bad "IDLE_IN_TRANSACTION_SESSION_TIMEOUT=${timeout} not passed through" ;;
	esac
done
for timeout in 5parsecs -1 1.5h 30MIN 25d 3000000000 99999999999h; do
	cmd=$(tunevars 4096 300 POSTGRES_TUNED_CMD IDLE_IN_TRANSACTION_SESSION_TIMEOUT=${timeout})
	case "${cmd}" in
		*"-c idle_in_transaction_session_timeout=30min "*)
			warned IDLE_IN_TRANSACTION_SESSION_TIMEOUT && ok "IDLE_IN_TRANSACTION_SESSION_TIMEOUT=${timeout} falls back to 30min with a warning" \
				|| bad "IDLE_IN_TRANSACTION_SESSION_TIMEOUT=${timeout} fell back without a warning" ;;
		*) bad "IDLE_IN_TRANSACTION_SESSION_TIMEOUT=${timeout} did not fall back to 30min" ;;
	esac
done

# 14. Five connections are kept for superusers (so that administration and the memory guard get in
# when max_connections is exhausted), always fewer than max_connections.
cmd=$(tunevars 4096 300 POSTGRES_TUNED_CMD)
case "${cmd}" in
	*"-c superuser_reserved_connections=5 "*) ok "superuser_reserved_connections is 5" ;;
	*) bad "superuser_reserved_connections=5 missing from the tuned command" ;;
esac
case "${cmd}" in
	*"-c compute_query_id=on "*) ok "compute_query_id is on, so the guard can log query_id" ;;
	*) bad "compute_query_id=on missing from the tuned command" ;;
esac
cmd=$(tunevars 4096 4 POSTGRES_TUNED_CMD)
case "${cmd}" in
	*"-c max_connections=4 "*"-c superuser_reserved_connections=3 "*) ok "4 connections keep 3 for superusers" ;;
	*) bad "4 connections: superuser_reserved_connections not lowered to 3" ;;
esac

# 15. Sizes from 1 GiB to a 352 GiB / 62-CPU container, on PostgreSQL 18. effective_cache_size is
# a share of the whole limit (EFFECTIVE_CACHE_SIZE_PERC), between shared buffers and the limit;
# maintenance_work_mem is split over the autovacuum workers and MAINTENANCE_WORK_MEM_SESSIONS only,
# within [1 MB, MAINTENANCE_WORK_MEM_MAX], and budgeted for what they can take; autovacuum_max_workers
# stays within the 16 autovacuum_worker_slots; parallel workers per gather stay at the fixed cap of
# 2; the reserve is kept. The last column is 7.4.0's maintenance_work_mem (kB) at the same size, measured
# with this harness on its script ("-" where it is not compared).
for case in "1024 2 300 2 -" "4096 4 300 2 -" "16384 8 300 2 -" "65536 16 2500 2 191739" \
	"262144 32 2500 2 433264" "360448 62 5500 2 186211" "360448 62 8000 2 146309"; do
	# shellcheck disable=SC2086
	set -- ${case}; memory=$1; cpus=$2; connections=$3; cap=$4; before=$5
	# shellcheck disable=SC2046
	set -- $(tunevars "${memory}" "${connections}" "MAX_MEMORY SHARED_BUFFERS EFFECTIVE_CACHE_SIZE MAINTENANCE_WORK_MEM MAINTENANCE_WORK_MEM_MAX AUTOVACUUM_MAX_WORKERS MAX_PARALLEL_WORKERS_PER_GATHER_MAX MAX_PARALLEL_WORKERS_PER_GATHER ACTUAL_RESERVED_MEMORY_PERC TOTAL_MAINTENANCE_WORK_MEM MAINTENANCE_PROCESSES" \
		TEST_CPUS="${cpus}" PG_MAJOR=18)
	label="${memory} MB / ${cpus} CPUs / ${connections} connections"
	if [ "$#" -eq 11 ] && is_number "$3" && [ "$3" -ge "$2" ] && [ "$3" -le "$1" ]
	then ok "${label}: effective_cache_size $3 kB within [shared_buffers $2, limit $1]"
	else bad "${label}: effective_cache_size '$3', shared_buffers '$2', limit '$1'"
	fi
	is_number "$4" && [ "$4" -ge 1024 ] && [ "$4" -le "$5" ] && [ "${10}" = $(( $4 * ${11} )) ] \
		&& ok "${label}: maintenance_work_mem $4 kB within [1024, $5], budgeted for ${11} processes" \
		|| bad "${label}: maintenance_work_mem '$4' (cap '$5'), budgeted '${10}' for '${11}' processes"
	if [ "${before}" != - ]
	then
		[ "$4" -gt "${before}" ] && ok "${label}: maintenance_work_mem $4 kB above 7.4.0's ${before} kB" \
			|| bad "${label}: maintenance_work_mem '$4' not above 7.4.0's ${before} kB"
	fi
	is_number "$6" && [ "$6" -le 16 ] && ok "${label}: autovacuum_max_workers $6 within the 16 slots" \
		|| bad "${label}: autovacuum_max_workers '$6' above the 16 slots"
	[ "$7" = "${cap}" ] && is_number "$8" && [ "$8" -le "${cap}" ] && ok "${label}: parallel cap ${cap}, $8 per gather" \
		|| bad "${label}: parallel cap '$7' (expected ${cap}), '$8' per gather"
	is_number "$9" && [ "$9" -ge 15 ] && ok "${label}: the reserve is kept ($9%)" || bad "${label}: reserve '$9'% below 15%"
	if [ "${memory}" = 360448 ]
	then
		[ "$3" -ge 157286400 ] && ok "${label}: effective_cache_size $(( $3 / 1048576 )) GiB, at least 150 GiB" \
			|| bad "${label}: effective_cache_size '$3' kB below 150 GiB"
	fi
done

# 15b. effective_cache_size: EFFECTIVE_CACHE_SIZE_PERC is a share of the limit, clamped to 100 and
# never below shared buffers; anything but a number falls back to 60 with a warning. It allocates
# nothing, so it moves no other setting.
# shellcheck disable=SC2046
set -- $(tunevars 360448 5500 "MAX_MEMORY EFFECTIVE_CACHE_SIZE SHARED_BUFFERS WORK_MEM" TEST_CPUS=62 PG_MAJOR=18 EFFECTIVE_CACHE_SIZE_PERC=40)
ecs_limit=$1; sb_40=$3; wm_40=$4
[ "$2" = $(( $1 * 40 / 100 )) ] && ok "EFFECTIVE_CACHE_SIZE_PERC=40 gives 40% of the limit ($2 kB)" || bad "EFFECTIVE_CACHE_SIZE_PERC=40 gave '$2' kB of '$1'"
# shellcheck disable=SC2046
set -- $(tunevars 360448 5500 "EFFECTIVE_CACHE_SIZE SHARED_BUFFERS WORK_MEM" TEST_CPUS=62 PG_MAJOR=18 EFFECTIVE_CACHE_SIZE_PERC=150)
[ "$1" = "${ecs_limit}" ] && [ "$2" = "${sb_40}" ] && [ "$3" = "${wm_40}" ] \
	&& ok "EFFECTIVE_CACHE_SIZE_PERC=150 is clamped to the limit, and moves neither shared_buffers nor work_mem" \
	|| bad "EFFECTIVE_CACHE_SIZE_PERC=150: '$1' kB (limit ${ecs_limit}), shared_buffers '$2' (${sb_40}), work_mem '$3' (${wm_40})"
# shellcheck disable=SC2046
set -- $(tunevars 4096 300 "EFFECTIVE_CACHE_SIZE SHARED_BUFFERS" EFFECTIVE_CACHE_SIZE_PERC=1)
is_number "$1" && [ "$1" = "$2" ] && ok "EFFECTIVE_CACHE_SIZE_PERC=1 is floored at shared_buffers ($2 kB)" || bad "EFFECTIVE_CACHE_SIZE_PERC=1 gave '$1' kB, shared_buffers '$2'"
# shellcheck disable=SC2046
set -- $(tunevars 4096 300 "MAX_MEMORY EFFECTIVE_CACHE_SIZE" EFFECTIVE_CACHE_SIZE_PERC=abc)
[ "$2" = $(( $1 * 60 / 100 )) ] && warned EFFECTIVE_CACHE_SIZE_PERC && ok "EFFECTIVE_CACHE_SIZE_PERC=abc falls back to 60 with a warning" \
	|| bad "EFFECTIVE_CACHE_SIZE_PERC=abc gave '$2' kB of '$1'"
ecs=$(tunevars 4096 300 EFFECTIVE_CACHE_SIZE)
cmd=$(tunevars 4096 300 POSTGRES_TUNED_CMD)
case "${cmd}" in
	*"-c effective_cache_size=${ecs}kB "*) ok "effective_cache_size=${ecs}kB is passed to the server" ;;
	*) bad "effective_cache_size=${ecs}kB missing from the tuned command" ;;
esac

# 15c. maintenance_work_mem: MAINTENANCE_WORK_MEM_MAX caps it, and what the cap leaves over goes
# back to the other settings or the reserve; below 1024 kB the cap is raised with a warning.
# Parallel maintenance workers do not divide it; MAINTENANCE_WORK_MEM_SESSIONS does.
# shellcheck disable=SC2046
set -- $(tunevars 360448 5500 "TOTAL_MAINTENANCE_WORK_MEM SHARED_BUFFERS ACTUAL_RESERVED_MEMORY" TEST_CPUS=62 PG_MAJOR=18)
total_default=$1; sb_default=$2; reserve_default=$3
# shellcheck disable=SC2046
set -- $(tunevars 360448 5500 "MAINTENANCE_WORK_MEM TOTAL_MAINTENANCE_WORK_MEM SHARED_BUFFERS ACTUAL_RESERVED_MEMORY" TEST_CPUS=62 PG_MAJOR=18 MAINTENANCE_WORK_MEM_MAX=65536)
if [ "$1" = 65536 ] && is_number "${total_default}" && [ "$2" -lt "${total_default}" ] \
	&& { [ "$3" -gt "${sb_default}" ] || [ "$4" -gt "${reserve_default}" ]; }
then ok "MAINTENANCE_WORK_MEM_MAX=65536 caps it and gives the rest back (budgeted ${total_default} -> $2 kB, shared_buffers ${sb_default} -> $3 kB)"
else bad "MAINTENANCE_WORK_MEM_MAX=65536: maintenance_work_mem '$1', budgeted '$2' (was ${total_default}), shared_buffers '$3', reserve '$4'"
fi
mwm=$(tunevars 4096 300 MAINTENANCE_WORK_MEM MAINTENANCE_WORK_MEM_MAX=100)
[ "${mwm}" = 1024 ] && warned MAINTENANCE_WORK_MEM_MAX && ok "MAINTENANCE_WORK_MEM_MAX=100 is raised to 1024 with a warning" \
	|| bad "MAINTENANCE_WORK_MEM_MAX=100 gave maintenance_work_mem '${mwm}'"
mwm_few=$(tunevars 16384 300 MAINTENANCE_WORK_MEM TEST_CPUS=8 PG_MAJOR=18 MAX_PARALLEL_MAINTENANCE_WORKERS_PERC=1)
mwm_many=$(tunevars 16384 300 MAINTENANCE_WORK_MEM TEST_CPUS=8 PG_MAJOR=18 MAX_PARALLEL_MAINTENANCE_WORKERS_PERC=100)
is_number "${mwm_few}" && [ "${mwm_few}" = "${mwm_many}" ] && ok "parallel maintenance workers do not divide maintenance_work_mem (${mwm_few} kB)" \
	|| bad "parallel maintenance workers changed maintenance_work_mem (${mwm_few} -> ${mwm_many} kB)"
mwm_sessions=$(tunevars 16384 300 MAINTENANCE_WORK_MEM TEST_CPUS=8 PG_MAJOR=18 MAINTENANCE_WORK_MEM_SESSIONS=10)
is_number "${mwm_sessions}" && [ "${mwm_sessions}" -lt "${mwm_few}" ] && ok "more MAINTENANCE_WORK_MEM_SESSIONS leave each a smaller share (${mwm_few} -> ${mwm_sessions} kB)" \
	|| bad "MAINTENANCE_WORK_MEM_SESSIONS=10 gave '${mwm_sessions}' kB (2 give ${mwm_few})"

# 15d. autovacuum_max_workers is capped at the 16 autovacuum_worker_slots on PostgreSQL 18 only
# (62 CPUs give 37 otherwise), and the server processes are budgeted for the workers that run.
# shellcheck disable=SC2046
set -- $(tunevars 360448 5500 "AUTOVACUUM_MAX_WORKERS SERVER_PROCESSES" TEST_CPUS=62 PG_MAJOR=17); avw17=$1; procs17=$2
# shellcheck disable=SC2046
set -- $(tunevars 360448 5500 "AUTOVACUUM_MAX_WORKERS SERVER_PROCESSES SERVER_LOCK_SLOTS MAX_WORKER_PROCESSES MAX_WAL_SENDERS" TEST_CPUS=62 PG_MAJOR=18)
if [ "${avw17}" = 37 ] && [ "$1" = 16 ] && [ "$2" = $(( procs17 - 37 + 16 + 3 )) ] && [ "$3" = $(( $4 + 16 + 1 + $5 )) ]
then ok "62 CPUs: autovacuum_max_workers 37 on PostgreSQL 17, 16 on 18 (server processes ${procs17} -> $2, lock slots $3)"
else bad "62 CPUs: autovacuum_max_workers '${avw17}' on 17, '$1' on 18; server processes ${procs17} -> '$2', lock slots '$3'"
fi
cmd=$(tunevars 360448 5500 POSTGRES_TUNED_CMD TEST_CPUS=62 PG_MAJOR=18)
case "${cmd}" in
	*"-c autovacuum_max_workers=16 "*) ok "autovacuum_max_workers=16 is passed on PostgreSQL 18" ;;
	*) bad "autovacuum_max_workers=16 missing from the PostgreSQL 18 command" ;;
esac

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
