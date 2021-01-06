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
	cp /tmp/pg_hba.conf ${PGDATA}/pg_hba.conf
	ensubst < ${PGDATA}/pg_hba.conf > ${PGDATA}/pg_hba.conf
fi
# Configures database
./psql_configure.sh &

# Executes the init command.
exec $@