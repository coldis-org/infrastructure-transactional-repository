#!/bin/sh

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true
DEBUG_OPT=
REPLICATION_LOCK_FILE=${PGDATA}/replication_configured.lock

# Enables interruption signal handling.
trap - INT TERM


# If the replication has not been configured yet.
if [ "${FORCE_BACKUP}" = "true" ]
then
	echo "Removing replication file"
	rm ${REPLICATION_LOCK_FILE}
fi

if [ ! -f ${REPLICATION_LOCK_FILE} ] 
then

	# Cleans data.
	rm -rf ${PGDATA}/*

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
	# Starts replication streaming.
	(echo ${POSTGRES_REPLICATOR_PASSWORD} | pg_basebackup ${BACKUP_PARAMS} --create-slot) || \
	( \
		(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -h "${MASTER_ENDPOINT}" -c "SELECT pg_drop_replication_slot('${REPLICATION_SLOT_NAME}');" -U ${POSTGRES_ADMIN_USER}) \
		&& (echo ${POSTGRES_REPLICATOR_PASSWORD} | pg_basebackup ${BACKUP_PARAMS} --create-slot) \
	)
	# Sets that replication has been configured.
	touch ${REPLICATION_LOCK_FILE}

fi

# Makes sure the permissions are set.
echo "Changing folder permissions"
chmod 750 ${PGDATA} -R
chown postgres ${PGDATA} -R

# Tune command.
. ./psql_tune_cmd.sh
psql_tune_cmd "$@"

# Check if master address and LDAP has changed
. ./psql_update_conn.sh --skip-reload


# Executes the init command.
echo "exec env POSTGRES_USER=${POSTGRES_ADMIN_USER} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD} ${POSTGRES_TUNED_CMD}"
exec env POSTGRES_USER=${POSTGRES_ADMIN_USER} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD} ${POSTGRES_TUNED_CMD}
