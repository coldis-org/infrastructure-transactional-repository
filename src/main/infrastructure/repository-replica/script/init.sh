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
	echo ${POSTGRES_REPLICATOR_PASSWORD} | pg_basebackup -h ${MASTER_ENDPOINT} -p ${MASTER_PORT} -D ${PGDATA} -PRv -U ${POSTGRES_REPLICATOR_USER} -X stream --checkpoint=fast
	# Stes that replication has been configured.
	touch ${REPLICATION_LOCK_FILE}

fi

# Makes sure the permissions are set.
chown postgres ${PGDATA} -R

# Starts the databse.
exec gosu postgres postgres
