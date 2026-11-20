#!/bin/sh

# Load side of memory_guard_sim.sh. Runs inside the simulation's client container (the image under
# test, entrypoint replaced by sleep), so the memory of every psql and pgbench here is charged to
# the client's cgroup, never to the database's. Only the backends it opens count there.
#
# Environment (set by the harness on the client container): SIM_DB_HOST, SIM_DB, SIM_ADMIN_USER,
# SIM_ADMIN_PW, SIM_APP_PW, SIM_REPL_USER, SIM_REPL_PW. Every session writes its output to
# /tmp/sim/<tag>.log and an "EXIT <status>" line when its psql ends.
#
# Subcommands:
#   pad TAG USER CHUNKS BYTES GAP  idle bloat: CHUNKS set_config pads of BYTES each, GAP seconds
#                                  apart, then idle on an open stdin for as long as the container
#   canary                         one session that reports its backend pid every second
#   hog TAG USER MB_PER_S ROWS     active hog: array_agg of 10 kB rows, paced to MB_PER_S (0 means
#                                  unpaced); prints its backend pid before and after
#   writer                         one insert every 0.2 s (the primary of S6)
#   receivewal                     pg_receivewal as the replication user (a WAL sender)
#   idle CLIENTS SECONDS           CLIENTS idle connections held by one pgbench
#   bench_init SCALE               pgbench -i
#   bench SECONDS CLIENTS          TPC-B-like pgbench; prints "tps avg_ms p95_ms p99_ms count"
#   sql USER QUERY                 one query, unaligned output

set -u

LOG_DIR=/tmp/sim
mkdir -p "${LOG_DIR}"

# Password of a user.
sim_password() {
	case $1 in
		"${SIM_ADMIN_USER}") echo "${SIM_ADMIN_PW}" ;;
		"${SIM_REPL_USER:-}") echo "${SIM_REPL_PW:-}" ;;
		*) echo "${SIM_APP_PW}" ;;
	esac
}

# psql as USER with application_name APP; the rest are psql arguments.
sim_psql() {
	sim_user=$1
	sim_app=$2
	shift 2
	PGPASSWORD=$(sim_password "${sim_user}") PGAPPNAME=${sim_app} PGCONNECT_TIMEOUT=5 \
		psql -X -h "${SIM_DB_HOST}" -U "${sim_user}" -d "${SIM_DB:-simapp}" "$@"
}

case ${1:-} in

	pad)
		tag=$2 user=$3 chunks=$4 bytes=$5 gap=$6
		{
			i=1
			while [ "${i}" -le "${chunks}" ]
			do
				echo "SELECT 'pad', pg_backend_pid(), length(set_config('sim.pad${i}', repeat('x', ${bytes}), false));"
				sleep "${gap}"
				i=$(( i + 1 ))
			done
			echo "SELECT 'padded', pg_backend_pid();"
			exec sleep 1000000
		} | { sim_psql "${user}" "sim_${tag}" -At -v VERBOSITY=verbose; echo "EXIT $?"; } > "${LOG_DIR}/${tag}.log" 2>&1
		;;

	canary)
		while :
		do
			echo "SELECT 'canary', pg_backend_pid(), extract(epoch FROM now())::bigint;"
			sleep 1
		done | { sim_psql "${SIM_APP_USER:-simapp}" sim_canary -At; echo "EXIT $?"; } > "${LOG_DIR}/canary.log" 2>&1
		;;

	hog)
		tag=$2 user=$3 rate=$4 rows=$5
		# 10240-byte rows: rows per second is MB/s * 1048576 / 10240. Every 50th row sleeps until
		# that row's time since the statement began, so the pace corrects itself.
		rps=$(( rate * 1048576 / 10240 ))
		if [ "${rps}" -gt 0 ]
		then
			pace="WHERE g % 50 <> 0 OR pg_sleep(greatest(0, g::float8 / ${rps} - extract(epoch FROM clock_timestamp() - statement_timestamp()))) IS NOT NULL"
		else
			pace=
		fi
		{
			echo "SELECT 'before', pg_backend_pid();"
			echo "SELECT 'hog', cardinality(array_agg(x)) FROM (SELECT repeat('x', 10240) || g AS x FROM generate_series(1, ${rows}) g ${pace}) s;"
			echo "SELECT 'after', pg_backend_pid();"
		} | { sim_psql "${user}" "sim_${tag}" -At -v VERBOSITY=verbose; echo "EXIT $?"; } > "${LOG_DIR}/${tag}.log" 2>&1
		;;

	writer)
		sim_psql "${SIM_APP_USER:-simapp}" sim_writer -q -c 'CREATE TABLE IF NOT EXISTS sim_writes (at timestamptz)' > "${LOG_DIR}/writer.log" 2>&1
		while :
		do
			echo "INSERT INTO sim_writes VALUES (now());"
			sleep 0.2
		done | { sim_psql "${SIM_APP_USER:-simapp}" sim_writer -q; echo "EXIT $?"; } >> "${LOG_DIR}/writer.log" 2>&1
		;;

	receivewal)
		mkdir -p "${LOG_DIR}/wal"
		{ PGPASSWORD=${SIM_REPL_PW} pg_receivewal -h "${SIM_DB_HOST}" -U "${SIM_REPL_USER}" -D "${LOG_DIR}/wal" --no-sync; echo "EXIT $?"; } > "${LOG_DIR}/receivewal.log" 2>&1
		;;

	idle)
		clients=$2 seconds=$3
		printf 'SELECT 1;\n\\sleep %s s\n' "${seconds}" > "${LOG_DIR}/idle.sql"
		{ PGPASSWORD=${SIM_APP_PW} pgbench -n -c "${clients}" -j 8 -T "${seconds}" -f "${LOG_DIR}/idle.sql" \
			-h "${SIM_DB_HOST}" -U "${SIM_APP_USER:-simapp}" "${SIM_DB:-simapp}"; echo "EXIT $?"; } > "${LOG_DIR}/idle.log" 2>&1
		;;

	bench_init)
		PGPASSWORD=${SIM_APP_PW} pgbench -i -q -s "$2" -h "${SIM_DB_HOST}" -U "${SIM_APP_USER:-simapp}" "${SIM_DB:-simapp}" > "${LOG_DIR}/bench_init.log" 2>&1
		;;

	bench)
		seconds=$2 clients=$3
		dir=$(mktemp -d "${LOG_DIR}/bench.XXXXXX")
		cd "${dir}" || exit 1
		PGPASSWORD=${SIM_APP_PW} pgbench -n -c "${clients}" -j "${clients}" -T "${seconds}" -l \
			-h "${SIM_DB_HOST}" -U "${SIM_APP_USER:-simapp}" "${SIM_DB:-simapp}" > bench.out 2>&1 || { cat bench.out >&2; exit 1; }
		# Field 3 of the per-transaction log is the latency in microseconds.
		cat pgbench_log.* | awk '{ print $3 }' | sort -n | awk -v secs="${seconds}" '
			{ v[NR] = $1; sum += $1 }
			END {
				if (NR == 0) { print "0 0 0 0 0"; exit }
				p95 = v[int(NR * 0.95) > 0 ? int(NR * 0.95) : 1]
				p99 = v[int(NR * 0.99) > 0 ? int(NR * 0.99) : 1]
				printf "%.1f %.3f %.3f %.3f %d\n", NR / secs, sum / NR / 1000, p95 / 1000, p99 / 1000, NR
			}'
		;;

	sql)
		sim_psql "$2" sim_probe -At -v ON_ERROR_STOP=1 -c "$3"
		;;

	*)
		echo "unknown subcommand: ${1:-}" >&2
		exit 2
		;;

esac
