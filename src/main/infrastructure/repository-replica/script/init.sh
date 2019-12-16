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
if [ ! -f ${REPLICATION_LOCK_FILE} ]; then

	# Cleans data.
	rm -rf ${PGDATA}/*
	# Starts replication streaming.
	echo ${REPLICATOR_USER_PASSWORD} | pg_basebackup -h ${MASTER_ENDPOINT} -p ${MASTER_PORT} -D ${PGDATA} -PRv -U ${REPLICATOR_USER_NAME} -X stream
	chown postgres ${PGDATA} -R
	# Stes that replication has been configured.
	touch ${REPLICATION_LOCK_FILE}

fi

# Starts the databse.
exec gosu postgres postgres
