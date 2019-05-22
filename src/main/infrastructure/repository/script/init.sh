#!/bin/sh

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true
DEBUG_OPT=
SQL_CONFIGURATION=/tmp/config.sql
USER_LOCK_FILE="${PGDATA}/user_configured.lock"
JSON_CAST_LOCK_FILE="${PGDATA}/json_cast_configured.lock"
UNACCENT_LOCK_FILE="${PGDATA}/unaccent_configured.lock"
REPLICATION_LOCK_FILE="${PGDATA}/replication_configured.lock"

# Enables interruption signal handling.
trap - INT TERM

# Updates the conf file.
${DEBUG} && echo  "Updating config"
rm -Rf ${PGDATA}/postgresql.conf
cp /tmp/postgresql.conf ${PGDATA}/postgresql.conf
rm -Rf ${PGDATA}/pg_hba.conf
cp /tmp/pg_hba.conf ${PGDATA}/pg_hba.conf

# If the user has not been (and should) configured yet.
if [ ! -f ${USER_LOCK_FILE} ] && [ "${USER_NAME}" != "" ] 
then

	${DEBUG} && echo  "Configuring default database"
	
	# Creates the default user.
	psql -c "CREATE USER ${USER_NAME} WITH PASSWORD '${USER_PASSWORD}';" -U postgres
	
	# Creates the default database.
	psql -c "CREATE DATABASE ${DATABASE_NAME} OWNER ${USER_NAME};" -U postgres

	# Creates the lock.
	touch ${USER_LOCK_FILE}
	
fi

# If the JSON has not been (and should) configured yet.
if [ ! -f ${JSON_CAST_LOCK_FILE} ] && [ "${ENABLE_JSON_CAST}" == "true" ] 
then

	${DEBUG} && echo  "Configuring JSON cast"

	# Creates the JSON casts.
	psql -c "CREATE CAST (varchar as json) WITHOUT FUNCTION AS IMPLICIT;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE CAST (json as varchar) WITHOUT FUNCTION AS IMPLICIT;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE FUNCTION varchar_to_jsonb(varchar) RETURNS jsonb AS ' SELECT \$1::json::jsonb; ' LANGUAGE SQL IMMUTABLE;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE CAST (varchar AS jsonb) WITH FUNCTION varchar_to_jsonb(varchar) AS IMPLICIT;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE FUNCTION jsonb_to_varchar(jsonb) RETURNS varchar AS ' SELECT \$1::json::varchar; ' LANGUAGE SQL IMMUTABLE;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE CAST (jsonb AS varchar) WITH FUNCTION jsonb_to_varchar(jsonb) AS IMPLICIT;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE FUNCTION text_to_jsonb(text) RETURNS jsonb AS ' SELECT \$1::json::jsonb; ' LANGUAGE SQL IMMUTABLE;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE CAST (text AS jsonb) WITH FUNCTION text_to_jsonb(text) AS IMPLICIT;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE FUNCTION jsonb_to_text(jsonb) RETURNS text AS ' SELECT \$1::json::text; ' LANGUAGE SQL IMMUTABLE;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE CAST (jsonb AS text) WITH FUNCTION jsonb_to_text(jsonb) AS IMPLICIT;" -U postgres ${DATABASE_NAME} ${USER_NAME}

	# Creates the lock.
	touch ${JSON_CAST_LOCK_FILE}

fi

# If unaccent extension should be confgured.
if [ ! -f ${UNACCENT_LOCK_FILE} ] && [ "${ENABLE_UNACCENT}" == "true" ] 
then

	${DEBUG} && echo  "Configuring unaccent extension"

	# Creates unaccent extension.
	psql -c "CREATE EXTENSION IF NOT EXISTS unaccent;" -U postgres ${DATABASE_NAME} ${USER_NAME}
	psql -c "CREATE FUNCTION immutable_unaccent(text) RETURNS text LANGUAGE SQL IMMUTABLE AS 'SELECT unaccent(\$1)';" -U postgres ${DATABASE_NAME} ${USER_NAME}

	# Creates the lock.
	touch ${UNACCENT_LOCK_FILE}

fi

# If the JSON has not been (and should) configured yet.
if [ ! -f ${REPLICATION_LOCK_FILE} ] && [ "${REPLICATOR_USER_NAME}" != "" ]
then
	
	${DEBUG} && echo  "Configuring replication"

	# Also creates the replication user.
	psql -c "CREATE USER ${REPLICATOR_USER_NAME} REPLICATION LOGIN ENCRYPTED PASSWORD '${REPLICATOR_USER_PASSWORD}';" -U postgres

	# Creates the lock.
	touch ${REPLICATION_LOCK_FILE}

fi

# If there is a configuration file.
if [ -f ${SQL_CONFIGURATION} ]
then
	
	${DEBUG} && echo  "Configuring database"

	# Also creates the replication user.
	psql -a -f ${SQL_CONFIGURATION} -U ${USER_NAME} ${DATABASE_NAME} 

fi
