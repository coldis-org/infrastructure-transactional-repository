#!/bin/sh

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true
DEBUG_OPT=

# Enables interruption signal handling.
trap - INT TERM

# Moves the data of a previous deployment into the data directory of this version, when it only
# has to be moved. Data of an older version is reported and left alone: migrating it is what the
# repository-upgrade image is for.
./psql_relocate.sh

# PG_VERSION is what initdb leaves behind: its presence means there is a cluster in the data
# directory, whatever state its configuration files are in.
if [ ! -f "${PGDATA}/PG_VERSION" ]
then
	# First run: initdb refuses a non empty directory, and a fresh volume may carry lost+found.
	echo "Removing lost+found folder to initialize"
	rm -rf "${PGDATA}/lost+found" || true
else
	# Makes sure configuration is updated. Overwrites in place rather than removing first, so a
	# boot interrupted half way never leaves the cluster without them, and restores them if they
	# went missing (the server does not start without postgresql.conf).
	${DEBUG} && echo "Updating configuration"
	cp /tmp/postgresql.conf "${PGDATA}/postgresql.conf"
	envsubst < /tmp/pg_hba.conf > "${PGDATA}/pg_hba.conf"
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

