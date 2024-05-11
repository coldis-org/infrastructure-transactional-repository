#!/bin/sh

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true
DEBUG_OPT=

# Enables interruption signal handling.
trap - INT TERM

# Makes sure configuration is updated
if [ -f ${PGDATA}/postgresql.conf ]
then
	${DEBUG} && echo "Updating configuration"
	rm -Rf ${PGDATA}/postgresql.conf
	cp /tmp/postgresql.conf ${PGDATA}/postgresql.conf
	rm -Rf ${PGDATA}/pg_hba.conf
	envsubst < /tmp/pg_hba.conf > ${PGDATA}/pg_hba.conf
fi

# To use cron
env > /etc/env_vars
chmod +x /etc/env_vars
service cron start

# Configures database
./psql_configure.sh &

# Tune command.
. ./psql_tune_cmd.sh
POSTGRES_CMD=$(psql_tune_cmd $@)

# Executes the init command.
echo "exec env POSTGRES_USER=${POSTGRES_ADMIN_USER} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD} ${POSTGRES_CMD}"
exec env POSTGRES_USER=${POSTGRES_ADMIN_USER} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD} ${POSTGRES_CMD}

