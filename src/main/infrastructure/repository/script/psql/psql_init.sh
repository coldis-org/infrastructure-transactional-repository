#!/bin/sh

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true
DEBUG_OPT=

# Enables interruption signal handling.
trap - INT TERM

# If it's first run
if [ -z "$(find ${PGDATA} -mindepth 1 -quit)" ]
then
	echo "Removing lost+found folder to initialize"
	rm -rf ${PGDATA}/lost+found || true
fi

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
psql_tune_cmd "$@"

# Check if LDAP has changed
. ./psql_update_conn.sh --skip-reload

# Executes the init command.
echo "exec env POSTGRES_USER=${POSTGRES_ADMIN_USER:=postgres} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD:=postgres} ${POSTGRES_TUNED_CMD}"
exec env POSTGRES_USER=${POSTGRES_ADMIN_USER:=postgres} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD:=postgres} ${POSTGRES_TUNED_CMD}

