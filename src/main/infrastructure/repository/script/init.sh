#!/bin/sh

# Default script behavior.
set -o errexit

# Debug is disabled by default.
DEBUG=false
DEBUG_OPT=

# Enables interruption signal handling.
trap - INT TERM

# Updates the conf file.
${DEBUG} && echo  "Updating config"
rm -Rf ${PGDATA}/postgresql.conf
cp /tmp/postgresql.conf ${PGDATA}/postgresql.conf
rm -Rf ${PGDATA}/pg_hba.conf
cp /tmp/pg_hba.conf ${PGDATA}/pg_hba.conf

# Configuration lock file.
USER_LOCK_FILE="${PGDATA}/user_configured.lock"
JSON_LOCK_FILE="${PGDATA}/json_configured.lock"
REPLICATION_LOCK_FILE="${PGDATA}/replication_configured.lock"

# If the user has not been (and should) configured yet.
if [ ! -f ${USER_LOCK_FILE} ] && [ "${USER_NAME}" != "" ] 
then

	${DEBUG} && echo  "Configuring default database"
	
	# Creates the default user.
	psql -c "CREATE USER ${USER_NAME} WITH PASSWORD '${USER_PASSWORD}';" -U postgres
	
	# Creates the default database.
	psql -c "CREATE DATABASE ${DATABASE_NAME} OWNER ${USER_NAME};" -U postgres
	
fi

# If the JSON has not been (and should) configured yet.
if [ ! -f ${JSON_LOCK_FILE} ] && [ "${ENABLE_JSON_STR_CAST}" == "true" ] 
then

	${DEBUG} && echo  "Configuring JSON"

	# Creates the JSON casts.
	psql -c "CREATE FUNCTION varchar_to_jsonb(varchar) RETURNS jsonb AS ' SELECT \$1::json::jsonb; ' LANGUAGE SQL IMMUTABLE; CREATE CAST (varchar AS jsonb) WITH FUNCTION varchar_to_jsonb(varchar) AS IMPLICIT; CREATE CAST (varchar as json) WITHOUT FUNCTION AS IMPLICIT;" -U postgres ${DATABASE_NAME} ${USER_NAME}

fi

# If the JSON has not been (and should) configured yet.
if [ ! -f ${REPLICATION_LOCK_FILE} ]
then
	
	${DEBUG} && echo  "Configuring replication"

	# Also creates the replication user.
	psql -c "CREATE USER ${REPLICATOR_USER_NAME} REPLICATION LOGIN ENCRYPTED PASSWORD '${REPLICATOR_PASSWORD}';" -U postgres

fi