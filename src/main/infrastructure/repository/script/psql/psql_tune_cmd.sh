#!/bin/sh

# Gets postgres tuned parameters.
psql_tune_cmd() {

	# Original command.
	ORIGINAL_POSTGRES_CMD="$@"
	POSTGRES_CMD=${ORIGINAL_POSTGRES_CMD}
	POSTGRES_ARGS=
	
	#MAX_CONNECTIONS=1000
	#MAX_WAL_SENDERS_RATIO=100
	#MAX_WORKER_PROCESSES=
	#MAX_WORKER_PROCESSES_RATIO=1
	#MAX_PARALLEL_WORKERS_RATIO=1
	#MAX_PARALLEL_MAINTENANCE_WORKERS_RATIO=4
	#AUTOVACUUM_MAX_WORKERS_RATIO=4
	#MAX_PARALLEL_WORKERS_PER_GATHER_RATIO=4
	#WAL_BUFFERS_RATIO=128
	#WAL_BUFFERS_MAX=16384
	#WAL_WRITER_FLUSH_AFTER_RATIO=64
	#WAL_WRITER_FLUSH_AFTER_MAX=131072
	#WAL_DECODE_BUFFER_SIZE_RATIO=64
	#WAL_DECODE_BUFFER_SIZE_MAX=131072
	#WAL_LOGICAL_DECODING_WORK_MEM_RATIO=64
	#WAL_LOGICAL_DECODING_WORK_MEM_MAX=262144
	#SHARED_BUFFER_RATIO=5
	#EFFECTIVE_CACHE_SIZE_RATIO=2
	#TOTAL_WORK_MEM_RATIO=8
	#TOTAL_MAINTENANCE_WORK_MEM_RATIO=16

	# If the command is to start postgres.
	if [ -z "${POSTGRES_CMD##*$postgres*}" ] 
	then
	
		# Wal senders.
		MAX_WAL_SENDERS=$((MAX_CONNECTIONS / MAX_WAL_SENDERS_RATIO))
		
		# CPU.
		CPU_UNIT=100000
		CPU_WORK_MULT=7
		if [ -z "${MAX_CPU}" ]
		then
			MAX_CPU=$(cat "/sys/fs/cgroup/cpu/cpu.cfs_quota_us" 2>/dev/null || echo "error")
		fi
		if [ -z "${MAX_CPU}" ] || [ "${MAX_CPU}" = "error" ] || [ ${MAX_CPU} -le 0 ]
		then
			MAX_CPU=$((1 * CPU_UNIT))
		fi
		MAX_CPU_WORK=$((MAX_CPU * CPU_WORK_MULT))
		
		# Workers.
		if [ -z "${MAX_WORKER_PROCESSES}" ]
		then 
			MAX_WORKER_PROCESSES=$((MAX_CPU_WORK / MAX_WORKER_PROCESSES_RATIO / CPU_UNIT))
			MAX_WORKER_PROCESSES=$((MAX_WORKER_PROCESSES < 1 ? 1 : MAX_WORKER_PROCESSES))
		fi
		MAX_PARALLEL_WORKERS=$((MAX_CPU_WORK / MAX_PARALLEL_WORKERS_RATIO / CPU_UNIT))
		MAX_PARALLEL_WORKERS=$((MAX_PARALLEL_WORKERS < 1 ? 1 : MAX_PARALLEL_WORKERS))
		MAX_PARALLEL_MAINTENANCE_WORKERS=$((MAX_CPU_WORK / MAX_PARALLEL_MAINTENANCE_WORKERS_RATIO / CPU_UNIT))
		MAX_PARALLEL_MAINTENANCE_WORKERS=$((MAX_PARALLEL_MAINTENANCE_WORKERS < 1 ? 1 : MAX_PARALLEL_MAINTENANCE_WORKERS))
		AUTOVACUUM_MAX_WORKERS=$((MAX_CPU_WORK / AUTOVACUUM_MAX_WORKERS_RATIO / CPU_UNIT))
		AUTOVACUUM_MAX_WORKERS=$((AUTOVACUUM_MAX_WORKERS < 1 ? 1 : AUTOVACUUM_MAX_WORKERS))
		MAX_PARALLEL_WORKERS_PER_GATHER=$((MAX_CPU_WORK / MAX_PARALLEL_WORKERS_PER_GATHER_RATIO / CPU_UNIT))
		MAX_PARALLEL_WORKERS_PER_GATHER=$((MAX_PARALLEL_WORKERS_PER_GATHER < 1 ? 1 : MAX_PARALLEL_WORKERS_PER_GATHER))
		
		# Max memory.
		if [ -z "${MAX_MEMORY}" ]
		then
			MAX_MEMORY=$(cat "/sys/fs/cgroup/memory/memory.limit_in_bytes" 2>/dev/null || echo "error")
		fi
		if [ -z "${MAX_MEMORY}" ] || [ "${MAX_MEMORY}" = "error" ] || [ ${MAX_MEMORY} -le 0 ]
		then
			MAX_MEMORY=$((1024 * 1024 * 1024)) # Default to 1G.
		fi
		MAX_MEMORY=$((MAX_MEMORY / 1024))
		
		# Wal memory.
		WAL_BUFFERS=$((MAX_MEMORY / WAL_BUFFERS_RATIO))
		WAL_BUFFERS=$((WAL_BUFFERS > WAL_BUFFERS_MAX ? WAL_BUFFERS_MAX : WAL_BUFFERS))
		WAL_WRITER_FLUSH_AFTER=$((MAX_MEMORY / WAL_WRITER_FLUSH_AFTER_RATIO))
		WAL_WRITER_FLUSH_AFTER=$((WAL_WRITER_FLUSH_AFTER > WAL_WRITER_FLUSH_AFTER_MAX ? WAL_WRITER_FLUSH_AFTER_MAX : WAL_WRITER_FLUSH_AFTER))
		WAL_DECODE_BUFFER_SIZE=$((MAX_MEMORY / WAL_DECODE_BUFFER_SIZE_RATIO))
		WAL_DECODE_BUFFER_SIZE=$((WAL_DECODE_BUFFER_SIZE > WAL_DECODE_BUFFER_SIZE_MAX ? WAL_DECODE_BUFFER_SIZE_MAX : WAL_DECODE_BUFFER_SIZE))
		LOGICAL_DECODING_WORK_MEM=$((MAX_MEMORY / LOGICAL_DECODING_WORK_MEM_RATIO))
		LOGICAL_DECODING_WORK_MEM=$((LOGICAL_DECODING_WORK_MEM > LOGICAL_DECODING_WORK_MEM_MAX ? LOGICAL_DECODING_WORK_MEM_MAX : LOGICAL_DECODING_WORK_MEM))
		
		# Overall memory.
		SHARED_BUFFERS=$((MAX_MEMORY / SHARED_BUFFERS_RATIO))
		EFFECTIVE_CACHE_SIZE=$((MAX_MEMORY / EFFECTIVE_CACHE_SIZE_RATIO))
		TOTAL_WORK_MEM=$((MAX_MEMORY / TOTAL_WORK_MEM_RATIO))
		WORK_MEM=$((TOTAL_WORK_MEM / MAX_CONNECTIONS))
		TOTAL_MAINTENANCE_WORK_MEM=$((MAX_MEMORY / TOTAL_MAINTENANCE_WORK_MEM_RATIO))
		MAINTENANCE_WORK_MEM=$((TOTAL_MAINTENANCE_WORK_MEM / (MAX_PARALLEL_MAINTENANCE_WORKERS + AUTOVACUUM_MAX_WORKERS)))
		
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
		 -c max_files_per_process=8388608\
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
		 -c min_wal_size=16GB \
		 -c max_wal_size=16GB \
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
			POSTGRES_GIVEN_ARGS=$(expr substr "${ORIGINAL_POSTGRES_CMD}" "$((POSTGRES_CMD_LEN + 2))" "$((ORIGINAL_POSTGRES_CMD_LEN - POSTGRES_CMD_LEN))")
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

