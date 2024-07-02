#!/bin/sh

# Memory limit.
memory_limit() {
	default_mem=$(( 1024 * 1024 * 1024 )) # 1GB
	max_mem=9223372036854771712
	mem=$( cat "/sys/fs/cgroup/memory/memory.limit_in_bytes" 2>/dev/null )
	if [ -z "${mem}" ] || [ "${mem}" = "${max_mem}" ]
	then
		mem="${default_mem}"
	fi
	echo "${mem}"
}
echo "memory_limit=$(memory_limit)"

disk_limit() {
	df --output=size --total ${PGDATA} | tail -1
}
echo "disk_limit=$(disk_limit)"

# Gets postgres tuned parameters.
psql_tune_cmd() {

	# Original command.
	ORIGINAL_POSTGRES_CMD="$@"
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
	
		# Wal senders.
		MAX_WAL_SENDERS=$(( MAX_CONNECTIONS * MAX_WAL_SENDERS_CONN_PERC / 100 ))
		
		# CPU.
		CPU_UNIT=100000
		if [ -z "${MAX_CPU}" ]
		then
			MAX_CPU=$(cat "/sys/fs/cgroup/cpu/cpu.cfs_quota_us" 2>/dev/null || echo "error")
		fi
		if [ -z "${MAX_CPU}" ] || [ "${MAX_CPU}" = "error" ] || [ ${MAX_CPU} -le 0 ]
		then
			MAX_CPU=$(( 1 * CPU_UNIT ))
		fi
		MAX_CPU_WORK=$(( MAX_CPU * CPU_WORK_PERC / 100 ))
		
		# Workers.
		if [ -z "${MAX_WORKER_PROCESSES}" ]
		then 
			MAX_WORKER_PROCESSES=$(( MAX_CPU_WORK * MAX_WORKER_PROCESSES_PERC / 100 / CPU_UNIT ))
			MAX_WORKER_PROCESSES=$(( MAX_WORKER_PROCESSES < 1 ? 1 : MAX_WORKER_PROCESSES ))
		fi
		MAX_PARALLEL_WORKERS=$(( MAX_CPU_WORK * MAX_PARALLEL_WORKERS_PERC / 100 / CPU_UNIT ))
		MAX_PARALLEL_WORKERS=$(( MAX_PARALLEL_WORKERS < 1 ? 1 : MAX_PARALLEL_WORKERS ))
		MAX_PARALLEL_WORKERS=$(( MAX_PARALLEL_WORKERS > MAX_WORKER_PROCESSES ? MAX_WORKER_PROCESSES : MAX_PARALLEL_WORKERS ))
		MAX_PARALLEL_MAINTENANCE_WORKERS=$(( MAX_CPU_WORK * MAX_PARALLEL_MAINTENANCE_WORKERS_PERC / 100 / CPU_UNIT ))
		MAX_PARALLEL_MAINTENANCE_WORKERS=$(( MAX_PARALLEL_MAINTENANCE_WORKERS < 1 ? 1 : MAX_PARALLEL_MAINTENANCE_WORKERS ))
		MAX_PARALLEL_MAINTENANCE_WORKERS=$(( MAX_PARALLEL_MAINTENANCE_WORKERS > MAX_WORKER_PROCESSES ? MAX_WORKER_PROCESSES : MAX_PARALLEL_MAINTENANCE_WORKERS ))
		AUTOVACUUM_MAX_WORKERS=$(( MAX_CPU_WORK * AUTOVACUUM_MAX_WORKERS_PERC / 100 / CPU_UNIT ))
		AUTOVACUUM_MAX_WORKERS=$(( AUTOVACUUM_MAX_WORKERS < 1 ? 1 : AUTOVACUUM_MAX_WORKERS ))
		AUTOVACUUM_MAX_WORKERS=$(( AUTOVACUUM_MAX_WORKERS > MAX_WORKER_PROCESSES ? MAX_WORKER_PROCESSES : AUTOVACUUM_MAX_WORKERS ))
		MAX_PARALLEL_WORKERS_PER_GATHER=$(( MAX_CPU_WORK * MAX_PARALLEL_WORKERS_PER_GATHER_PERC / 100 / CPU_UNIT ))
		MAX_PARALLEL_WORKERS_PER_GATHER=$(( MAX_PARALLEL_WORKERS_PER_GATHER < 1 ? 1 : MAX_PARALLEL_WORKERS_PER_GATHER ))
		MAX_PARALLEL_WORKERS_PER_GATHER=$(( MAX_PARALLEL_WORKERS_PER_GATHER > MAX_WORKER_PROCESSES ? MAX_WORKER_PROCESSES : MAX_PARALLEL_WORKERS_PER_GATHER ))
		
		# Max memory.
		if [ -z "${MAX_MEMORY}" ]
		then
			MAX_MEMORY=$( memory_limit 2>/dev/null || echo "error" )
		fi
		if [ -z "${MAX_MEMORY}" ] || [ "${MAX_MEMORY}" = "error" ] || [ ${MAX_MEMORY} -le 0 ]
		then
			MAX_MEMORY=$(( 1024 * 1024 * 1024 )) # Default to 1G.
		fi
		MAX_MEMORY=$(( MAX_MEMORY / 1024 ))
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
			WORK_MEM=$(( TOTAL_WORK_MEM / MAX_CONNECTIONS ))
			TOTAL_MAINTENANCE_WORK_MEM=$(( NON_RESERVED_MAX_MEMORY * TOTAL_MAINTENANCE_WORK_MEM_PERC / 100 ))
			MAINTENANCE_WORK_MEM=$(( TOTAL_MAINTENANCE_WORK_MEM / (MAX_PARALLEL_MAINTENANCE_WORKERS + AUTOVACUUM_MAX_WORKERS )))
			
			# Updates reserved memory.
			TOTAL_CONFIGURED_MEMORY=$(( WAL_BUFFERS + WAL_WRITER_FLUSH_AFTER + WAL_DECODE_BUFFER_SIZE + TOTAL_LOGICAL_DECODING_WORK_MEM + SHARED_BUFFERS + TOTAL_WORK_MEM + TOTAL_MAINTENANCE_WORK_MEM ))
			ACTUAL_RESERVED_MEMORY=$(( MAX_MEMORY - TOTAL_CONFIGURED_MEMORY ))
			ACTUAL_RESERVED_MEMORY_PERC=$(( ACTUAL_RESERVED_MEMORY * 100 / MAX_MEMORY ))
			NON_RESERVED_MAX_MEMORY=$(( NON_RESERVED_MAX_MEMORY - (MAX_MEMORY / 50 )))
#			echo "MAX_MEMORY=${MAX_MEMORY}"
#			echo "TOTAL_CONFIGURED_MEMORY=${TOTAL_CONFIGURED_MEMORY}"
#			echo "ACTUAL_RESERVED_MEMORY=${ACTUAL_RESERVED_MEMORY}"
#			echo "ACTUAL_RESERVED_MEMORY_RATIO=${ACTUAL_RESERVED_MEMORY_RATIO}"
#			echo "NON_RESERVED_MAX_MEMORY=${NON_RESERVED_MAX_MEMORY}"
			
		done
		
		# Disk config.
		DISK_SIZE=$(disk_limit)
		DISK_SIZE_MB=$(( DISK_SIZE / 1024 ))
		MIN_WAL_SIZE=$(( DISK_SIZE_MB * MIN_WAL_SIZE_DISC_PERC / 100 ))
		MIN_WAL_SIZE=$(( MIN_WAL_SIZE > MIN_WAL_SIZE_MAX ? MIN_WAL_SIZE_MAX : MIN_WAL_SIZE ))
		MAX_WAL_SIZE=$(( DISK_SIZE_MB * MAX_WAL_SIZE_DISC_PERC / 100 ))
		MAX_WAL_SIZE=$(( MAX_WAL_SIZE > MAX_WAL_SIZE_MAX ? MAX_WAL_SIZE_MAX : MAX_WAL_SIZE ))
		WAL_KEEP_SIZE=$(( DISK_SIZE_MB * WAL_KEEP_SIZE_DISC_PERC / 100 ))
		MAX_SLOT_WAL_KEEP_SIZE=$(( DISK_SIZE_MB * MAX_SLOT_WAL_KEEP_SIZE_DISC_PERC / 100 ))

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
		 -c lock_timeout=3min \
		 -c deadlock_timeout=1s \
		 -c default_statistics_target=500 \
		 -c jit=on \
		 -c max_locks_per_transaction=16384 \
		 -c max_pred_locks_per_transaction=16384 \
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
	echo "${POSTGRES_CMD} ${POSTGRES_ARGS}"
	
}

