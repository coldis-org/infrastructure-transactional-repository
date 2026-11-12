#!/bin/sh

# Default script behavior.
set -o errexit

# Default parameters.
REPLICATION_LOCK_FILE=${PGDATA}/replication_configured.lock

# Enables interruption signal handling.
trap - INT TERM


# Drops the slot on the copy source, terminating whatever still holds it. A dead replica can leave
# its walsender alive on the master (see wal_sender_timeout), and then the slot stays "active" and
# cannot be dropped, so terminate first and retry. Silent no-op when the slot does not exist, which
# makes this safe to run both on a fresh replica and on a rebuild.
psql_reset_slot() {
	if [ -z "${REPLICATION_SLOT_NAME}" ]
	then
		return 0
	fi
	echo "Resetting replication slot ${REPLICATION_SLOT_NAME} on ${COPY_ENDPOINT}:${COPY_PORT}"
	ATTEMPT=0
	while [ ${ATTEMPT} -lt 10 ]
	do
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -h "${COPY_ENDPOINT}" -p "${COPY_PORT}" \
			-U "${POSTGRES_ADMIN_USER}" -v ON_ERROR_STOP=1 \
			-c "SELECT pg_terminate_backend(active_pid) FROM pg_replication_slots WHERE slot_name = '${REPLICATION_SLOT_NAME}' AND active;" \
			-c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '${REPLICATION_SLOT_NAME}';" \
			&& return 0
		ATTEMPT=$(( ATTEMPT + 1 ))
		sleep 3
	done
	echo "Could not reset replication slot ${REPLICATION_SLOT_NAME}"
	return 1
}


# If the replication has not been configured yet.
if [ "${FORCE_BACKUP}" = "true" ]
then
	echo "Removing replication file"
	rm -f ${REPLICATION_LOCK_FILE}
fi

if [ ! -f ${REPLICATION_LOCK_FILE} ] 
then

	# Cleans data.
	rm -rf "${PGDATA:?}"/*

	# Sets the slot.
	SLOT_PARAM=
	if [ ! -z "${REPLICATION_SLOT_NAME}" ]
	then
		SLOT_PARAM="--slot=${REPLICATION_SLOT_NAME}"
	fi

	# Uses one if other is not available.	
	if [ -z "${COPY_ENDPOINT}" ]
	then
		COPY_ENDPOINT="${MASTER_ENDPOINT}"
	else
		if [ -z "${MASTER_ENDPOINT}" ]
		then
			MASTER_ENDPOINT="${COPY_ENDPOINT}"
		fi
	fi

	BACKUP_PARAMS="""--host=${COPY_ENDPOINT} --port=${COPY_PORT} --pgdata=${PGDATA} --username=${POSTGRES_REPLICATOR_USER}\
					 --wal-method=stream  --write-recovery-conf --checkpoint=fast --progress --verbose ${SLOT_PARAM}"""
	# Makes sure no leftover slot from a previous run blocks --create-slot.
	psql_reset_slot

	# Starts replication streaming.
	echo ${POSTGRES_REPLICATOR_PASSWORD} | pg_basebackup ${BACKUP_PARAMS} --create-slot
	# Sets that replication has been configured.
	touch ${REPLICATION_LOCK_FILE}

fi

# Makes sure the permissions are set.
echo "Changing folder permissions"
chmod 750 ${PGDATA} -R
chown postgres ${PGDATA} -R

# From PostgreSQL 18 on the data directory sits in a folder named after the major version, and
# pg_basebackup creates that folder along with the data directory, as root and 0700. The chown
# above only reaches inside the data directory, so postgres is left unable to traverse into it
# and the server stops at "could not access directory". Nothing below the parent is touched:
# a volume holding other versions keeps them as they are.
PGDATA_PARENT=$(dirname ${PGDATA})
if [ "$(basename ${PGDATA_PARENT})" = "${PG_MAJOR}" ]
then
	chmod 750 ${PGDATA_PARENT}
	chown postgres ${PGDATA_PARENT}
fi

# A standby refuses to start when any of the settings below is lower than on its primary, and
# both sides tune them from their own CPU and memory, so a replica smaller than its primary would
# not come up. They are raised here to the primary's. pg_control holds the values the primary last
# recorded, which are the ones the standby is checked against: reading it needs neither the
# primary up nor a credential, and pg_basebackup has always written it by now. pg_controldata
# speaks the image's pt_BR, hence the C locale. Only while this is a standby: once promoted,
# pg_control holds the server's own settings, and reading them back would only ever raise them.
primary_setting() {
	[ -f "${PGDATA}/standby.signal" ] || return 0
	LC_ALL=C pg_controldata "${PGDATA}" | awk -v key="$1 setting:" 'index($0, key) == 1 { print $NF }'
}

# The two that size memory go in before the tuner budgets it. MAX_LOCKS_PER_TRANSACTION_MIN is
# its last clamp, so the floor wins over a lower maximum. Only tuners from the 7.1.0 base size the
# lock table; older ones (Dockerfile5/6) fix max_locks_per_transaction at 16384 on both sides, so
# that floor does nothing there, but the connections floor still applies and grows the 16384-row
# lock table with them, unbudgeted: a replica too small for that fails at shared memory allocation
# rather than with PostgreSQL's "insufficient parameter settings" (it did not start before either).
PRIMARY_MAX_CONNECTIONS=$(primary_setting max_connections)
PRIMARY_MAX_LOCKS_PER_TRANSACTION=$(primary_setting max_locks_per_xact)
echo "Primary recorded max_connections=${PRIMARY_MAX_CONNECTIONS} max_locks_per_transaction=${PRIMARY_MAX_LOCKS_PER_TRANSACTION}"
MAX_CONNECTIONS=$(( MAX_CONNECTIONS < PRIMARY_MAX_CONNECTIONS ? PRIMARY_MAX_CONNECTIONS : MAX_CONNECTIONS ))
MAX_LOCKS_PER_TRANSACTION_MIN=$(( MAX_LOCKS_PER_TRANSACTION_MIN < PRIMARY_MAX_LOCKS_PER_TRANSACTION ? PRIMARY_MAX_LOCKS_PER_TRANSACTION : MAX_LOCKS_PER_TRANSACTION_MIN ))

# Tune command.
. ./psql_tune_cmd.sh

# The other three a standby checks are applied on top of what the tuner chose, when theirs are
# lower: max_worker_processes (the tuner takes it from the CPU), max_wal_senders (a share of
# max_connections, which a deployment can set apart on either side) and max_prepared_transactions
# (the tuner leaves it to postgresql.conf, which the replica only gets with its base backup, so a
# primary that raises it later is not followed). PostgreSQL takes the last -c of a setting.
# Each worker, sender and prepared transaction is one more row of max_locks_per_transaction in the
# lock table, which the tuner sizes for the connections alone, keeping MIN_RESERVED_MEMORY free for
# backends and the kernel with only a few MB to spare. So a dry run (in a subshell: nothing it sets
# leaks) gives the values and lock size the tuner picks here, and the extra rows are added to the
# reserve the real run keeps: the tuner makes room for them in the other settings instead of the
# rows eating the headroom, which would leave a replica that starts and is later killed by the
# kernel with nothing in its log. On bases before 7.1.0 the tuner does not size the lock table
# (MAX_LOCKS_PER_TRANSACTION stays empty), and Postgres is left to stop on its own.
PRIMARY_MAX_WORKER_PROCESSES=$(primary_setting max_worker_processes)
PRIMARY_MAX_WAL_SENDERS=$(primary_setting max_wal_senders)
PRIMARY_MAX_PREPARED_TRANSACTIONS=$(primary_setting max_prepared_xacts)
RESERVED_MEMORY_FLOOR=${MIN_RESERVED_MEMORY}
EXTRA_WORKERS=0
EXTRA_WAL_SENDERS=0
EXTRA_PREPARED_TRANSACTIONS=0
EXTRA_LOCK_SLOTS=0
EXTRA_LOCKS_MEMORY=0
if [ -n "${PRIMARY_MAX_WORKER_PROCESSES}" ]
then
	DRY_RUN=$( (psql_tune_cmd "$@" >/dev/null 2>&1; echo "${MAX_WORKER_PROCESSES:-0} ${MAX_WAL_SENDERS:-0} ${MAX_LOCKS_PER_TRANSACTION:-0}") )
	DRY_WORKERS=${DRY_RUN%% *}
	DRY_WAL_SENDERS=${DRY_RUN#* }; DRY_WAL_SENDERS=${DRY_WAL_SENDERS% *}
	DRY_LOCKS=${DRY_RUN##* }
	# What this replica's own postgresql.conf (from the base backup) sets; postgres -C reads it
	# without starting the server.
	REPLICA_MAX_PREPARED_TRANSACTIONS=$(gosu postgres postgres -C max_prepared_transactions -D "${PGDATA}" 2>/dev/null || echo 0)
	EXTRA_WORKERS=$(( PRIMARY_MAX_WORKER_PROCESSES - DRY_WORKERS ))
	EXTRA_WORKERS=$(( EXTRA_WORKERS < 0 ? 0 : EXTRA_WORKERS ))
	EXTRA_WAL_SENDERS=$(( PRIMARY_MAX_WAL_SENDERS - DRY_WAL_SENDERS ))
	EXTRA_WAL_SENDERS=$(( EXTRA_WAL_SENDERS < 0 ? 0 : EXTRA_WAL_SENDERS ))
	EXTRA_PREPARED_TRANSACTIONS=$(( PRIMARY_MAX_PREPARED_TRANSACTIONS - REPLICA_MAX_PREPARED_TRANSACTIONS ))
	EXTRA_PREPARED_TRANSACTIONS=$(( EXTRA_PREPARED_TRANSACTIONS < 0 ? 0 : EXTRA_PREPARED_TRANSACTIONS ))
	EXTRA_LOCK_SLOTS=$(( EXTRA_WORKERS + EXTRA_WAL_SENDERS + EXTRA_PREPARED_TRANSACTIONS ))
	EXTRA_LOCKS_MEMORY=$(( EXTRA_LOCK_SLOTS * DRY_LOCKS * 3 / 4 ))
	if [ ${EXTRA_LOCKS_MEMORY} -gt 0 ]
	then
		echo "Reserving $(( EXTRA_LOCKS_MEMORY / 1024 )) MB more for the lock rows of ${EXTRA_LOCK_SLOTS} slot(s) raised to the primary's (workers ${EXTRA_WORKERS}, WAL senders ${EXTRA_WAL_SENDERS}, prepared transactions ${EXTRA_PREPARED_TRANSACTIONS})"
		MIN_RESERVED_MEMORY=$(( MIN_RESERVED_MEMORY + EXTRA_LOCKS_MEMORY ))
	fi
fi
psql_tune_cmd "$@"
if [ ${EXTRA_WORKERS} -gt 0 ]
then
	echo "Raising max_worker_processes from ${MAX_WORKER_PROCESSES} to the primary's ${PRIMARY_MAX_WORKER_PROCESSES}"
	POSTGRES_TUNED_CMD="${POSTGRES_TUNED_CMD} -c max_worker_processes=${PRIMARY_MAX_WORKER_PROCESSES}"
fi
if [ ${EXTRA_WAL_SENDERS} -gt 0 ]
then
	echo "Raising max_wal_senders from ${MAX_WAL_SENDERS} to the primary's ${PRIMARY_MAX_WAL_SENDERS}"
	POSTGRES_TUNED_CMD="${POSTGRES_TUNED_CMD} -c max_wal_senders=${PRIMARY_MAX_WAL_SENDERS}"
fi
if [ ${EXTRA_PREPARED_TRANSACTIONS} -gt 0 ]
then
	echo "Raising max_prepared_transactions from ${REPLICA_MAX_PREPARED_TRANSACTIONS} to the primary's ${PRIMARY_MAX_PREPARED_TRANSACTIONS}"
	POSTGRES_TUNED_CMD="${POSTGRES_TUNED_CMD} -c max_prepared_transactions=${PRIMARY_MAX_PREPARED_TRANSACTIONS}"
fi

# A lock table larger than the memory leaves the tuner nothing for the rest, and it goes on below
# zero rather than failing, so Postgres would stop at whichever value broke its minimum first. The
# reserve itself needs no check: the tuner only stops once it keeps MIN_RESERVED_MEMORY, which
# already includes the extra rows, so a replica that cannot afford them ends up here, with the other
# settings shrunk below their minimums. Stop with the sizes.
if [ -n "${MAX_LOCKS_PER_TRANSACTION}" ]
then
	EXTRA_LOCKS_MEMORY=$(( EXTRA_LOCK_SLOTS * MAX_LOCKS_PER_TRANSACTION * 3 / 4 ))
	if [ ${SHARED_BUFFERS} -lt 128 ] || [ ${WORK_MEM} -lt 64 ] || [ ${MAINTENANCE_WORK_MEM} -lt 1024 ]
	then
		echo "Not enough memory: max_locks_per_transaction=${MAX_LOCKS_PER_TRANSACTION} over $(( MAX_CONNECTIONS + EXTRA_LOCK_SLOTS )) slots takes $(( (TOTAL_LOCKS_MEMORY + EXTRA_LOCKS_MEMORY) / 1024 )) MB of lock table, out of $(( MAX_MEMORY / 1024 )) MB with $(( RESERVED_MEMORY_FLOOR / 1024 )) MB kept free. Give the replica more memory, or the primary a lower max_locks_per_transaction."
		exit 1
	fi
fi

# Check if master address and LDAP has changed. The dot command takes no arguments in sh/dash, so
# --skip-reload goes in as positional parameters (the exec below uses POSTGRES_TUNED_CMD, not
# "$@"); without it the script reloads a server that is not running yet.
set -- --skip-reload
. ./psql_update_conn.sh


# Executes the init command.
echo "exec env POSTGRES_USER=${POSTGRES_ADMIN_USER} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD} ${POSTGRES_TUNED_CMD}"
exec env POSTGRES_USER=${POSTGRES_ADMIN_USER} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD} ${POSTGRES_TUNED_CMD}
