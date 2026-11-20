#!/bin/sh


# Gets postgres tuned parameters.
psql_tune_cmd() {

	# Original command.
	ORIGINAL_POSTGRES_CMD="$*"
	POSTGRES_CMD=${ORIGINAL_POSTGRES_CMD}
	POSTGRES_ARGS=
	
#	MAX_CONNECTIONS=1000
#	MAX_WAL_SENDERS_CONN_PERC=10
#	CPU_WORK_PERC=300
#	MAX_WORKER_PROCESSES=
#	MAX_WORKER_PROCESSES_PERC=100
#	MAX_PARALLEL_WORKERS_PERC=100
#	MAX_PARALLEL_MAINTENANCE_WORKERS_PERC=20
#	AUTOVACUUM_MAX_WORKERS_PERC=20
#	MAX_PARALLEL_WORKERS_PER_GATHER_PERC=20
#	MIN_RESERVED_MEMORY_PERC=10
#	MIN_RESERVED_MEMORY=131072
#	WAL_BUFFERS_PERC=1
#	WAL_BUFFERS_MAX=16384
#	WAL_WRITER_FLUSH_AFTER_PERC=2
#	WAL_WRITER_FLUSH_AFTER_MAX=131072
#	WAL_DECODE_BUFFER_SIZE_PERC=2
#	WAL_DECODE_BUFFER_SIZE_MAX=131072
#	TOTAL_LOGICAL_DECODING_WORK_MEM_PERC=2
#	TOTAL_LOGICAL_DECODING_WORK_MEM_MAX=262144
#	SHARED_BUFFERS_PERC=25
#	EFFECTIVE_CACHE_SIZE_PERC=50
#	TOTAL_WORK_MEM_PERC=13
#	TOTAL_MAINTENANCE_WORK_MEM_PERC=5

	# If the command is to start postgres.
	if [ -z "${POSTGRES_CMD##*$postgres*}" ] 
	then
	
		# OS limits. Probe disk on the closest existing ancestor of PGDATA — PGDATA itself, and
		# even its immediate parent, may not exist on first boot (the Postgres image creates the
		# version-specific subdirectory during initdb). Walk up until we hit a directory that is
		# present, so df returns a real disk size instead of failing silently to 0 MB.
		DISK_PATH=${PGDATA}
		while [ -n "${DISK_PATH}" ] && [ "${DISK_PATH}" != "/" ] && [ ! -d "${DISK_PATH}" ]
		do
			DISK_PATH=$(dirname "${DISK_PATH}")
		done
		. os_limits
		available_cpus
		available_memory
		available_disk

		# CPU.
		if [ -z "${MAX_CPU}" ]
		then
			MAX_CPU="${AVAILABLE_CPUS}"
		fi
		MAX_CPU_WORK=$(( MAX_CPU * CPU_WORK_PERC / 100 ))

		# Max memory.
		if [ -z "${MAX_MEMORY}" ]
		then
			MAX_MEMORY=$(( AVAILABLE_MEMORY * 1024 ))
		fi

		# Connections. Each connection is a server process with private memory of its own
		# (catalog and plan caches, buffers of the protocol) that none of the settings below
		# limit, so the connection limit is bounded by the memory set aside for it rather than
		# taken as given: refusing a connection is recoverable, the kernel killing the server is
		# not. CONNECTION_MEMORY is in kB, like every memory value in this function.
		CONNECTION_MEMORY=${CONNECTION_MEMORY:-16384}
		CONNECTIONS_MEMORY_MAX_PERC=${CONNECTIONS_MEMORY_MAX_PERC:-35}
		CONNECTION_SHARED_BUFFERS_MAPPED_PERC=${CONNECTION_SHARED_BUFFERS_MAPPED_PERC:-35}
		WORK_MEM_OPERATIONS=${WORK_MEM_OPERATIONS:-2}
		# Both divide below: a zero (or negative) value would stop the entrypoint on a shell
		# arithmetic error, so it is raised to 1 with a warning instead.
		if [ ${CONNECTION_MEMORY} -lt 1 ] || [ ${WORK_MEM_OPERATIONS} -lt 1 ]
		then
			echo "WARN: CONNECTION_MEMORY=${CONNECTION_MEMORY} and WORK_MEM_OPERATIONS=${WORK_MEM_OPERATIONS} must be at least 1; raising them." >&2
			CONNECTION_MEMORY=$(( CONNECTION_MEMORY < 1 ? 1 : CONNECTION_MEMORY ))
			WORK_MEM_OPERATIONS=$(( WORK_MEM_OPERATIONS < 1 ? 1 : WORK_MEM_OPERATIONS ))
		fi
		HUGE_PAGES=${HUGE_PAGES:-try}
		case "${HUGE_PAGES}" in
			on|off|try) ;;
			*)
				echo "WARN: HUGE_PAGES=${HUGE_PAGES} is not on, off or try; using try." >&2
				HUGE_PAGES=try
				;;
		esac
		# Share of the connections expected to run a query at the same time, which work_mem is
		# split over (1 to 100). At 100 every connection may sort at once; a pool that keeps most
		# connections idle can lower it and get a larger work_mem for the same total.
		WORK_MEM_ACTIVE_PERC=${WORK_MEM_ACTIVE_PERC:-100}
		if [ ${WORK_MEM_ACTIVE_PERC} -lt 1 ] || [ ${WORK_MEM_ACTIVE_PERC} -gt 100 ]
		then
			echo "WARN: WORK_MEM_ACTIVE_PERC=${WORK_MEM_ACTIVE_PERC} is not between 1 and 100; clamping it." >&2
			WORK_MEM_ACTIVE_PERC=$(( WORK_MEM_ACTIVE_PERC < 1 ? 1 : 100 ))
		fi
		# Parallel workers a single query may take for each gather. Each one is a server process
		# with its own work_mem for every sort or hash it runs, so a query with N workers can take
		# N+1 times the memory of a serial one: a percentage of the CPUs alone gives a large host
		# tens of workers per query, which suits a warehouse and not a transactional database.
		MAX_PARALLEL_WORKERS_PER_GATHER_MAX=${MAX_PARALLEL_WORKERS_PER_GATHER_MAX:-4}
		# Sessions left idle inside a transaction hold their locks, snapshot and memory until
		# they are ended. 0 disables.
		IDLE_IN_TRANSACTION_SESSION_TIMEOUT=${IDLE_IN_TRANSACTION_SESSION_TIMEOUT:-30min}
		# Floors for a standby, which refuses to start below its primary's values (its init sets
		# them); they are budgeted like any other process.
		MAX_WORKER_PROCESSES_MIN=${MAX_WORKER_PROCESSES_MIN:-0}
		MAX_WAL_SENDERS_MIN=${MAX_WAL_SENDERS_MIN:-0}
		REQUESTED_MAX_CONNECTIONS=${MAX_CONNECTIONS}

		# Wal senders, from the requested connection limit: they do not count against
		# max_connections, so lowering them with the cap would cut replication for nothing.
		MAX_WAL_SENDERS=$(( REQUESTED_MAX_CONNECTIONS * MAX_WAL_SENDERS_CONN_PERC / 100 ))
		MAX_WAL_SENDERS=$(( MAX_WAL_SENDERS < 2 ? 2 : MAX_WAL_SENDERS ))
		MAX_WAL_SENDERS=$(( MAX_WAL_SENDERS < MAX_WAL_SENDERS_MIN ? MAX_WAL_SENDERS_MIN : MAX_WAL_SENDERS ))

		# Workers.
		if [ -z "${MAX_WORKER_PROCESSES}" ]
		then
			MAX_WORKER_PROCESSES=$(( MAX_CPU_WORK * MAX_WORKER_PROCESSES_PERC / 100 ))
			MAX_WORKER_PROCESSES=$(( MAX_WORKER_PROCESSES < 1 ? 1 : MAX_WORKER_PROCESSES ))
		fi
		MAX_WORKER_PROCESSES=$(( MAX_WORKER_PROCESSES < MAX_WORKER_PROCESSES_MIN ? MAX_WORKER_PROCESSES_MIN : MAX_WORKER_PROCESSES ))
		MAX_PARALLEL_WORKERS=$(( MAX_CPU_WORK * MAX_PARALLEL_WORKERS_PERC / 100 ))
		MAX_PARALLEL_WORKERS=$(( MAX_PARALLEL_WORKERS < 1 ? 1 : MAX_PARALLEL_WORKERS ))
		MAX_PARALLEL_WORKERS=$(( MAX_PARALLEL_WORKERS > MAX_WORKER_PROCESSES ? MAX_WORKER_PROCESSES : MAX_PARALLEL_WORKERS ))
		MAX_PARALLEL_MAINTENANCE_WORKERS=$(( MAX_CPU_WORK * MAX_PARALLEL_MAINTENANCE_WORKERS_PERC / 100 ))
		MAX_PARALLEL_MAINTENANCE_WORKERS=$(( MAX_PARALLEL_MAINTENANCE_WORKERS < 1 ? 1 : MAX_PARALLEL_MAINTENANCE_WORKERS ))
		MAX_PARALLEL_MAINTENANCE_WORKERS=$(( MAX_PARALLEL_MAINTENANCE_WORKERS > MAX_WORKER_PROCESSES ? MAX_WORKER_PROCESSES : MAX_PARALLEL_MAINTENANCE_WORKERS ))
		AUTOVACUUM_MAX_WORKERS=$(( MAX_CPU_WORK * AUTOVACUUM_MAX_WORKERS_PERC / 100 ))
		AUTOVACUUM_MAX_WORKERS=$(( AUTOVACUUM_MAX_WORKERS < 1 ? 1 : AUTOVACUUM_MAX_WORKERS ))
		AUTOVACUUM_MAX_WORKERS=$(( AUTOVACUUM_MAX_WORKERS > MAX_WORKER_PROCESSES ? MAX_WORKER_PROCESSES : AUTOVACUUM_MAX_WORKERS ))
		MAX_PARALLEL_WORKERS_PER_GATHER=$(( MAX_CPU_WORK * MAX_PARALLEL_WORKERS_PER_GATHER_PERC / 100 ))
		MAX_PARALLEL_WORKERS_PER_GATHER=$(( MAX_PARALLEL_WORKERS_PER_GATHER < 1 ? 1 : MAX_PARALLEL_WORKERS_PER_GATHER ))
		MAX_PARALLEL_WORKERS_PER_GATHER=$(( MAX_PARALLEL_WORKERS_PER_GATHER > MAX_PARALLEL_WORKERS_PER_GATHER_MAX ? MAX_PARALLEL_WORKERS_PER_GATHER_MAX : MAX_PARALLEL_WORKERS_PER_GATHER ))
		MAX_PARALLEL_WORKERS_PER_GATHER=$(( MAX_PARALLEL_WORKERS_PER_GATHER > MAX_PARALLEL_WORKERS ? MAX_PARALLEL_WORKERS : MAX_PARALLEL_WORKERS_PER_GATHER ))
		MAX_PARALLEL_WORKERS_PER_GATHER=$(( MAX_PARALLEL_WORKERS_PER_GATHER < 0 ? 0 : MAX_PARALLEL_WORKERS_PER_GATHER ))

		# Server processes besides the client connections, each with private memory and page
		# tables of its own like a connection: the background workers (parallel query, logical
		# replication), the autovacuum workers, the WAL senders, and the fixed auxiliary ones
		# (checkpointer, background writer, WAL writer, autovacuum launcher, archiver or WAL
		# receiver, logical replication launcher). Lock table rows exist for each of them but the
		# auxiliary ones, as PostgreSQL sizes it over max_connections + autovacuum_max_workers + 1
		# + max_worker_processes + max_wal_senders.
		AUXILIARY_PROCESSES=6
		SERVER_PROCESSES=$(( MAX_WORKER_PROCESSES + AUTOVACUUM_MAX_WORKERS + MAX_WAL_SENDERS + AUXILIARY_PROCESSES ))
		SERVER_LOCK_SLOTS=$(( MAX_WORKER_PROCESSES + AUTOVACUUM_MAX_WORKERS + 1 + MAX_WAL_SENDERS ))

		# The connections' share is taken from the memory left once the reserve is kept, the same
		# reserve the budget below keeps. The other server processes come out of it first.
		RESERVE_MEMORY=$(( MAX_MEMORY * MIN_RESERVED_MEMORY_PERC / 100 ))
		RESERVE_MEMORY=$(( RESERVE_MEMORY < MIN_RESERVED_MEMORY ? MIN_RESERVED_MEMORY : RESERVE_MEMORY ))
		BUDGET_MEMORY=$(( MAX_MEMORY > RESERVE_MEMORY ? MAX_MEMORY - RESERVE_MEMORY : 0 ))
		CONNECTIONS_MEMORY_SHARE=$(( BUDGET_MEMORY * CONNECTIONS_MEMORY_MAX_PERC / 100 ))
		MAX_CONNECTIONS_FIT=$(( CONNECTIONS_MEMORY_SHARE / CONNECTION_MEMORY - SERVER_PROCESSES ))
		MAX_CONNECTIONS_FIT=$(( MAX_CONNECTIONS_FIT < 0 ? 0 : MAX_CONNECTIONS_FIT ))
		# Floors: at least 10 connections, and on a standby at least its primary's, or it refuses
		# to start (its init sets MAX_CONNECTIONS_MIN to the primary's value). When a floor is more
		# than the share holds, the connections' memory is capped at the share instead (each gets
		# less than CONNECTION_MEMORY): otherwise the budget below can never be met and every other
		# setting would shrink below Postgres' minimums, leaving a server that cannot start.
		MAX_CONNECTIONS_MIN=${MAX_CONNECTIONS_MIN:-0}
		MAX_CONNECTIONS_FLOOR=$(( MAX_CONNECTIONS_MIN < 10 ? 10 : MAX_CONNECTIONS_MIN ))
		CONNECTIONS_MEMORY_CAPPED=false
		if [ ${MAX_CONNECTIONS_FLOOR} -gt ${MAX_CONNECTIONS_FIT} ]
		then
			CONNECTIONS_MEMORY_CAPPED=true
			echo "WARN: ${MAX_CONNECTIONS_FLOOR} connections (the minimum, or the primary's) and ${SERVER_PROCESSES} other server processes do not fit in ${CONNECTIONS_MEMORY_SHARE}kB at ${CONNECTION_MEMORY}kB per process; capping their memory at that share." >&2
			MAX_CONNECTIONS_FIT=${MAX_CONNECTIONS_FLOOR}
		fi
		if [ ${MAX_CONNECTIONS} -gt ${MAX_CONNECTIONS_FIT} ]
		then
			echo "WARN: MAX_CONNECTIONS=${MAX_CONNECTIONS} does not fit in ${MAX_MEMORY}kB of memory at ${CONNECTION_MEMORY}kB per process (with ${SERVER_PROCESSES} other server processes); using ${MAX_CONNECTIONS_FIT}." >&2
			MAX_CONNECTIONS=${MAX_CONNECTIONS_FIT}
		fi

		# Page tables. Every process that touches shared buffers keeps its own page table
		# entries for them, 8 bytes for each 4 kB page (1/512 of what it maps), and they count
		# against the container's memory as much as the buffers themselves. With huge pages,
		# a page maps 2 MB and the cost becomes negligible. Only explicit 'on' is trusted, as
		# 'try' silently falls back to regular pages when none are available.
		PAGE_TABLE_RATIO=512
		if [ "${HUGE_PAGES}" = "on" ]
		then
			PAGE_TABLE_RATIO=262144
		fi

		# Disk size,
		if [ -z "${DISK_SIZE}" ]
		then
			DISK_SIZE="${AVAILABLE_DISK}"
		fi
		# Fall back to 1 GB when neither override nor probe yielded a value. Otherwise the WAL
		# size formulas below collapse to 0, which Postgres 17+ rejects (min_wal_size minimum
		# is 2 MB). This typically happens on first boot when df runs against a data dir that
		# initdb has not created yet.
		if [ -z "${DISK_SIZE}" ] || [ "${DISK_SIZE}" -eq 0 ]
		then
			DISK_SIZE=1073741824
		fi
		
		# Max memory. POSTGRES_TUNE_FAILED tells the caller the reserve could not be kept.
		# shellcheck disable=SC2034  # read by the script that sources this file
		POSTGRES_TUNE_FAILED=false
		NON_RESERVED_MAX_MEMORY=${MAX_MEMORY}
		TOTAL_CONFIGURED_MEMORY=0
		ACTUAL_RESERVED_MEMORY=$(( MAX_MEMORY - TOTAL_CONFIGURED_MEMORY ))
		ACTUAL_RESERVED_MEMORY_PERC=$(( ACTUAL_RESERVED_MEMORY * 100 / MAX_MEMORY ))

		# While reserved memory limits are not reached, calculates memory again.
		while [ ${TOTAL_CONFIGURED_MEMORY} -eq 0 ] || [ ${ACTUAL_RESERVED_MEMORY} -lt ${MIN_RESERVED_MEMORY} ] || [ ${ACTUAL_RESERVED_MEMORY_PERC} -lt ${MIN_RESERVED_MEMORY_PERC} ]
		do
		
			# Wal memory.
			WAL_BUFFERS=$(( NON_RESERVED_MAX_MEMORY * WAL_BUFFERS_PERC / 100 ))
			WAL_BUFFERS=$(( WAL_BUFFERS > WAL_BUFFERS_MAX ? WAL_BUFFERS_MAX : WAL_BUFFERS ))
			WAL_WRITER_FLUSH_AFTER=$(( NON_RESERVED_MAX_MEMORY * WAL_WRITER_FLUSH_AFTER_PERC / 100 ))
			WAL_WRITER_FLUSH_AFTER=$(( WAL_WRITER_FLUSH_AFTER > WAL_WRITER_FLUSH_AFTER_MAX ? WAL_WRITER_FLUSH_AFTER_MAX : WAL_WRITER_FLUSH_AFTER ))
			WAL_DECODE_BUFFER_SIZE=$(( NON_RESERVED_MAX_MEMORY * WAL_DECODE_BUFFER_SIZE_PERC / 100 ))
			WAL_DECODE_BUFFER_SIZE=$(( WAL_DECODE_BUFFER_SIZE > WAL_DECODE_BUFFER_SIZE_MAX ? WAL_DECODE_BUFFER_SIZE_MAX : WAL_DECODE_BUFFER_SIZE ))
			TOTAL_LOGICAL_DECODING_WORK_MEM=$(( NON_RESERVED_MAX_MEMORY * TOTAL_LOGICAL_DECODING_WORK_MEM_PERC / 100 ))
			LOGICAL_DECODING_WORK_MEM=$(( TOTAL_LOGICAL_DECODING_WORK_MEM / MAX_WAL_SENDERS ))
			LOGICAL_DECODING_WORK_MEM=$(( LOGICAL_DECODING_WORK_MEM > LOGICAL_DECODING_WORK_MEM_MAX ? LOGICAL_DECODING_WORK_MEM_MAX : LOGICAL_DECODING_WORK_MEM ))
			TOTAL_LOGICAL_DECODING_WORK_MEM=$(( LOGICAL_DECODING_WORK_MEM * MAX_WAL_SENDERS ))
			
			# Overall memory.
			SHARED_BUFFERS=$(( NON_RESERVED_MAX_MEMORY * SHARED_BUFFERS_PERC / 100 ))
			EFFECTIVE_CACHE_SIZE=$(( NON_RESERVED_MAX_MEMORY * EFFECTIVE_CACHE_SIZE_PERC / 100 ))
			TOTAL_WORK_MEM=$(( NON_RESERVED_MAX_MEMORY * TOTAL_WORK_MEM_PERC / 100 ))
			MIN_DYNAMIC_SHARED_MEMORY=$(( NON_RESERVED_MAX_MEMORY * MIN_DYNAMIC_SHARED_MEMORY_PERC / 100 ))
			# A query takes work_mem once per sort or hash node it runs (hashes take twice,
			# by hash_mem_multiplier), not once per connection; only the connections expected to
			# run a query at once take it, and every parallel worker running takes its own, so a
			# query with N workers per gather takes it N+1 times for each node.
			WORK_MEM_ACTIVE_CONNECTIONS=$(( MAX_CONNECTIONS * WORK_MEM_ACTIVE_PERC / 100 ))
			WORK_MEM_ACTIVE_CONNECTIONS=$(( WORK_MEM_ACTIVE_CONNECTIONS < 1 ? 1 : WORK_MEM_ACTIVE_CONNECTIONS ))
			WORK_MEM=$(( TOTAL_WORK_MEM / (WORK_MEM_ACTIVE_CONNECTIONS + MAX_PARALLEL_WORKERS) / WORK_MEM_OPERATIONS ))
			WORK_MEM=$(( WORK_MEM < 64 ? 64 : WORK_MEM ))
			TOTAL_MAINTENANCE_WORK_MEM=$(( NON_RESERVED_MAX_MEMORY * TOTAL_MAINTENANCE_WORK_MEM_PERC / 100 ))
			MAINTENANCE_WORK_MEM=$(( TOTAL_MAINTENANCE_WORK_MEM / (MAX_PARALLEL_MAINTENANCE_WORKERS + AUTOVACUUM_MAX_WORKERS )))
			
			# Lock tables. The shared memory they take is reserved at startup whether it is used
			# or not, and it grows with max_locks_per_transaction times the connection limit: a
			# fixed value large enough for a partitioned warehouse keeps a small database from
			# starting at all, since the kernel kills the server before it can report anything.
			# Measured at about 768 bytes, or three quarters of a kilobyte, for each lock slot of
			# each connection, covering the predicate lock table along with the regular one.
			TOTAL_LOCKS_MEMORY=$(( NON_RESERVED_MAX_MEMORY * TOTAL_LOCKS_MEMORY_PERC / 100 ))
			MAX_LOCKS_PER_TRANSACTION=$(( TOTAL_LOCKS_MEMORY * 4 / (MAX_CONNECTIONS * 3) ))
			MAX_LOCKS_PER_TRANSACTION=$(( MAX_LOCKS_PER_TRANSACTION > MAX_LOCKS_PER_TRANSACTION_MAX ? MAX_LOCKS_PER_TRANSACTION_MAX : MAX_LOCKS_PER_TRANSACTION ))
			MAX_LOCKS_PER_TRANSACTION=$(( MAX_LOCKS_PER_TRANSACTION < MAX_LOCKS_PER_TRANSACTION_MIN ? MAX_LOCKS_PER_TRANSACTION_MIN : MAX_LOCKS_PER_TRANSACTION ))
			# The table has a row for every other server process too, which takes memory the
			# same way: it is counted, though max_locks_per_transaction stays sized for the
			# connections alone.
			TOTAL_LOCKS_MEMORY=$(( MAX_LOCKS_PER_TRANSACTION * (MAX_CONNECTIONS + SERVER_LOCK_SLOTS) * 3 / 4 ))

			# Connections and the other server processes: the private memory of each process
			# plus the page tables for the part of shared buffers it maps. Shrinking shared
			# buffers shrinks the latter, which is what lets many connections fit at all without
			# huge pages.
			CONNECTION_PAGE_TABLES=$(( SHARED_BUFFERS * CONNECTION_SHARED_BUFFERS_MAPPED_PERC / 100 / PAGE_TABLE_RATIO ))
			TOTAL_CONNECTIONS_MEMORY=$(( (MAX_CONNECTIONS + SERVER_PROCESSES) * (CONNECTION_MEMORY + CONNECTION_PAGE_TABLES) ))
			if [ "${CONNECTIONS_MEMORY_CAPPED}" = true ] && [ ${TOTAL_CONNECTIONS_MEMORY} -gt ${CONNECTIONS_MEMORY_SHARE} ]
			then
				TOTAL_CONNECTIONS_MEMORY=${CONNECTIONS_MEMORY_SHARE}
			fi

			# Updates reserved memory.
			TOTAL_CONFIGURED_MEMORY=$(( WAL_BUFFERS + WAL_WRITER_FLUSH_AFTER + WAL_DECODE_BUFFER_SIZE + TOTAL_LOGICAL_DECODING_WORK_MEM + SHARED_BUFFERS + TOTAL_WORK_MEM + TOTAL_MAINTENANCE_WORK_MEM + TOTAL_LOCKS_MEMORY + TOTAL_CONNECTIONS_MEMORY ))
			ACTUAL_RESERVED_MEMORY=$(( MAX_MEMORY - TOTAL_CONFIGURED_MEMORY ))
			ACTUAL_RESERVED_MEMORY_PERC=$(( ACTUAL_RESERVED_MEMORY * 100 / MAX_MEMORY ))
			NON_RESERVED_MAX_MEMORY=$(( NON_RESERVED_MAX_MEMORY - (MAX_MEMORY / 50 )))
			# Guard against looping forever should the fixed costs alone not fit (memory below the
			# reserve itself, or a lock table that takes it all). The caller stops on
			# POSTGRES_TUNE_FAILED rather than start a server without its reserve: the last pass's
			# settings are not reliably below Postgres' minimums on a large container.
			if [ ${NON_RESERVED_MAX_MEMORY} -le 0 ]
			then
				# shellcheck disable=SC2034  # read by the script that sources this file
				POSTGRES_TUNE_FAILED=true
				echo "WARN: could not keep ${MIN_RESERVED_MEMORY_PERC}% and at least ${MIN_RESERVED_MEMORY}kB of ${MAX_MEMORY}kB in reserve (${MAX_CONNECTIONS} connections take ${TOTAL_CONNECTIONS_MEMORY}kB, the lock table ${TOTAL_LOCKS_MEMORY}kB); reserve is ${ACTUAL_RESERVED_MEMORY}kB." >&2
				break
			fi
#			echo "MAX_MEMORY=${MAX_MEMORY}"
#			echo "TOTAL_CONFIGURED_MEMORY=${TOTAL_CONFIGURED_MEMORY}"
#			echo "ACTUAL_RESERVED_MEMORY=${ACTUAL_RESERVED_MEMORY}"
#			echo "ACTUAL_RESERVED_MEMORY_RATIO=${ACTUAL_RESERVED_MEMORY_RATIO}"
#			echo "NON_RESERVED_MAX_MEMORY=${NON_RESERVED_MAX_MEMORY}"
			
		done
		
		# Disk config.
		DISK_SIZE_MB=$(( DISK_SIZE / 1024 / 1024 ))
		MIN_WAL_SIZE=$(( DISK_SIZE_MB * MIN_WAL_SIZE_DISC_PERC / 100 ))
		MAX_WAL_SIZE=$(( DISK_SIZE_MB * MAX_WAL_SIZE_DISC_PERC / 100 ))
		WAL_KEEP_SIZE=$(( DISK_SIZE_MB * WAL_KEEP_SIZE_DISC_PERC / 100 ))
		MAX_SLOT_WAL_KEEP_SIZE=$(( DISK_SIZE_MB * MAX_SLOT_WAL_KEEP_SIZE_DISC_PERC / 100 ))
		
		# Use default if exceeds max value
		MIN_WAL_SIZE=$(( MIN_WAL_SIZE > MIN_WAL_SIZE_MAX ? MIN_WAL_SIZE_MAX : MIN_WAL_SIZE ))
		MAX_WAL_SIZE=$(( MAX_WAL_SIZE > MAX_WAL_SIZE_MAX ? MAX_WAL_SIZE_MAX : MAX_WAL_SIZE ))
		MAX_SLOT_WAL_KEEP_SIZE=$(( MAX_SLOT_WAL_KEEP_SIZE > MAX_SLOT_WAL_KEEP_SIZE_MAX ? MAX_SLOT_WAL_KEEP_SIZE_MAX : MAX_SLOT_WAL_KEEP_SIZE ))

		# Floor min_wal_size / max_wal_size to 32 MB (two default WAL segments). Postgres rejects
		# values below 2 MB; staying at 32 MB keeps the database responsive on small disks.
		MIN_WAL_SIZE=$(( MIN_WAL_SIZE < 32 ? 32 : MIN_WAL_SIZE ))
		MAX_WAL_SIZE=$(( MAX_WAL_SIZE < 32 ? 32 : MAX_WAL_SIZE ))

		# Arguments.
		POSTGRES_TUNED_ARGS="\
 -c max_connections=${MAX_CONNECTIONS} \
 -c max_wal_senders=${MAX_WAL_SENDERS} \
 -c max_worker_processes=${MAX_WORKER_PROCESSES} \
 -c max_parallel_workers=${MAX_PARALLEL_WORKERS} \
 -c max_parallel_maintenance_workers=${MAX_PARALLEL_MAINTENANCE_WORKERS} \
 -c autovacuum_max_workers=${AUTOVACUUM_MAX_WORKERS} \
 -c max_parallel_workers_per_gather=${MAX_PARALLEL_WORKERS_PER_GATHER} \
 -c wal_buffers=${WAL_BUFFERS}kB \
 -c wal_writer_flush_after=${WAL_WRITER_FLUSH_AFTER}kB \
 -c wal_decode_buffer_size=${WAL_DECODE_BUFFER_SIZE}kB \
 -c logical_decoding_work_mem=${LOGICAL_DECODING_WORK_MEM}kB \
 -c shared_buffers=${SHARED_BUFFERS}kB \
 -c huge_pages=${HUGE_PAGES} \
 -c effective_cache_size=${EFFECTIVE_CACHE_SIZE}kB \
 -c work_mem=${WORK_MEM}kB \
 -c maintenance_work_mem=${MAINTENANCE_WORK_MEM}kB \
 -c min_dynamic_shared_memory=${MIN_DYNAMIC_SHARED_MEMORY}kB \
 -c max_files_per_process=8388608 \
 -c vacuum_cost_delay=1ms \
 -c vacuum_cost_limit=10000 \
 -c effective_io_concurrency=300 \
 -c maintenance_io_concurrency=100 \
 -c default_toast_compression=lz4 \
 -c wal_level=replica \
 -c wal_log_hints=off \
 -c wal_compression=on \
 -c synchronous_commit=on \
 -c wal_sync_method=fdatasync \
 -c wal_writer_delay=10s \
 -c min_wal_size=${MIN_WAL_SIZE}MB \
 -c max_wal_size=${MAX_WAL_SIZE}MB \
 -c wal_keep_size=${WAL_KEEP_SIZE}MB \
 -c max_slot_wal_keep_size=${MAX_SLOT_WAL_KEEP_SIZE}MB \
 -c checkpoint_completion_target=0.9 \
 -c checkpoint_timeout=20min \
 -c archive_mode=off \
 -c hot_standby=on \
 -c hot_standby_feedback=on \
 -c seq_page_cost=1.0 \
 -c random_page_cost=1.1 \
 -c cpu_tuple_cost=0.03 \
 -c log_min_duration_statement=2000 \
 -c autovacuum=on \
 -c autovacuum_vacuum_threshold=1235 \
 -c autovacuum_vacuum_scale_factor=0.001 \
 -c autovacuum_vacuum_insert_threshold=1235 \
 -c autovacuum_vacuum_insert_scale_factor=0.0005 \
 -c autovacuum_analyze_threshold=1235 \
 -c autovacuum_analyze_scale_factor=0.001 \
 -c autovacuum_vacuum_cost_delay=2ms \
 -c autovacuum_vacuum_cost_limit=10000 \
 -c statement_timeout=15min \
 -c idle_in_transaction_session_timeout=${IDLE_IN_TRANSACTION_SESSION_TIMEOUT} \
 -c lock_timeout=3min \
 -c deadlock_timeout=1s \
 -c default_statistics_target=500 \
 -c jit=on \
 -c max_locks_per_transaction=${MAX_LOCKS_PER_TRANSACTION} \
 -c max_pred_locks_per_transaction=${MAX_LOCKS_PER_TRANSACTION} \
 -c max_pred_locks_per_page=3 \
 -c max_pred_locks_per_relation=128 \
 -c max_standby_streaming_delay=2h \
 -c max_standby_archive_delay=2h \
		"
		ORIGINAL_POSTGRES_CMD_LEN=$(expr length "${ORIGINAL_POSTGRES_CMD}")
		POSTGRES_CMD=$(echo "${ORIGINAL_POSTGRES_CMD}" | sed -e "s/ -.*//")
		POSTGRES_CMD_LEN=$(expr length "${POSTGRES_CMD}")
		if [ ${ORIGINAL_POSTGRES_CMD_LEN} -gt ${POSTGRES_CMD_LEN} ]
		then
			POSTGRES_GIVEN_ARGS=$(expr substr "${ORIGINAL_POSTGRES_CMD}" "$(( POSTGRES_CMD_LEN + 2 ))" "$(( ORIGINAL_POSTGRES_CMD_LEN - POSTGRES_CMD_LEN ))")
		else
			POSTGRES_GIVEN_ARGS=
		fi
		POSTGRES_ARGS="${POSTGRES_TUNED_ARGS} ${POSTGRES_GIVEN_ARGS}"
		if [ "${OVERWRITE_TUNED_ARGS}" != "true" ]
		then
			POSTGRES_ARGS="${POSTGRES_GIVEN_ARGS} ${POSTGRES_TUNED_ARGS}"
		fi
		
	fi
	
	# Prints the modified command.
	# shellcheck disable=SC2034  # the result, read by the script that sources this file
	POSTGRES_TUNED_CMD="${POSTGRES_CMD} ${POSTGRES_ARGS}"
	
}

