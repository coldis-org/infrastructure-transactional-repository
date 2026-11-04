#!/bin/sh

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true

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
	# Makes sure configuration is updated, and restores it if it went missing (the server does
	# not start without postgresql.conf). Each file is written beside the live one and renamed
	# over it, so a boot interrupted half way leaves either the old file or the new one, never a
	# missing or truncated one.
	${DEBUG} && echo "Updating configuration"
	cp /tmp/postgresql.conf "${PGDATA}/postgresql.conf.new"
	mv "${PGDATA}/postgresql.conf.new" "${PGDATA}/postgresql.conf"
	envsubst < /tmp/pg_hba.conf > "${PGDATA}/pg_hba.conf.new"
	mv "${PGDATA}/pg_hba.conf.new" "${PGDATA}/pg_hba.conf"
fi

# To use cron
# Quoted, so values with spaces or ; survive being sourced by cron.
export -p > /etc/env_vars
chmod +x /etc/env_vars
service cron start

# Configures database
./psql_configure.sh &

# Tune command.
. ./psql_tune_cmd.sh
psql_tune_cmd "$@"

# Check if LDAP has changed. The dot command takes no arguments in sh/dash, so
# --skip-reload goes in as positional parameters (the exec below uses
# POSTGRES_TUNED_CMD, not "$@"); without it the script reloads a server that is
# not running yet.
set -- --skip-reload
. ./psql_update_conn.sh

# Executes the init command.
echo "exec env POSTGRES_USER=${POSTGRES_ADMIN_USER:=postgres} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD:=postgres} ${POSTGRES_TUNED_CMD}"
exec env POSTGRES_USER=${POSTGRES_ADMIN_USER:=postgres} POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASSWORD:=postgres} ${POSTGRES_TUNED_CMD}

