#!/bin/sh

# Default script behavior.
set +e

# Default parameters.
DEBUG=true
DEBUG_OPT=
SQL_CONFIGURATION=/tmp/config.sql
USER_LOCK_FILE="${PGDATA}/user_configured.lock"
REPLICATION_LOCK_FILE="${PGDATA}/replication_configured.lock"

# Enables interruption signal handling.
trap - INT TERM

# Waits until database is available.
while !(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c 'SELECT 1;' -v ON_ERROR_STOP=1 -U ${POSTGRES_ADMIN_USER})
do
	echo "Waiting database initialization"		
	sleep 10
done

# If the user has not been (and should) configured yet.
${DEBUG} && echo "POSTGRES_USER=${POSTGRES_USER}"
if [ ! -f "${USER_LOCK_FILE}" ] && [ "${POSTGRES_USER}" != "" ] 
then

	${DEBUG} && echo "Configuring default database"
	
	# Creates the default user.
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';" -U ${POSTGRES_ADMIN_USER}
	
	# Creates the default database.
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE DATABASE ${DATABASE_NAME} OWNER ${POSTGRES_USER};" -U ${POSTGRES_ADMIN_USER}

	# Creates the lock.
	touch ${USER_LOCK_FILE}
	
# If the user has been (or should not) configured yet.
else

	${DEBUG} && echo "Skipping default database"
	
fi

# Configures users.
./psql_users_remove.sh  || true
./psql_users_add.sh  || true

# If stats extension should be confgured.
${DEBUG} && echo "ENABLE_STATS=${ENABLE_STATS}"
if [ "${ENABLE_STATS}" != "false" ] 
then

	${DEBUG} && echo "Configuring stats extension"

	# Creates pg_trgm extension.
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}
	
# If stats extension should not be confgured.
else 

	${DEBUG} && echo "Skipping stats extension"

fi


# If the JSON has not been (and should) configured yet.
${DEBUG} && echo "ENABLE_JSON_CAST=${ENABLE_JSON_CAST}"
if [ "${ENABLE_JSON_CAST}" = "true" ] 
then

	${DEBUG} && echo "Configuring JSON cast"

	# Creates the JSON casts.
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE CAST (varchar as json) WITHOUT FUNCTION AS IMPLICIT;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME} || true
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE CAST (json as varchar) WITHOUT FUNCTION AS IMPLICIT;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME} || true
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE OR REPLACE FUNCTION varchar_to_jsonb(varchar) RETURNS jsonb AS ' SELECT \$1::json::jsonb; ' LANGUAGE SQL IMMUTABLE;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE CAST (varchar AS jsonb) WITH FUNCTION varchar_to_jsonb(varchar) AS IMPLICIT;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME} || true
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE OR REPLACE FUNCTION jsonb_to_varchar(jsonb) RETURNS varchar AS ' SELECT \$1::json::varchar; ' LANGUAGE SQL IMMUTABLE;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE CAST (jsonb AS varchar) WITH FUNCTION jsonb_to_varchar(jsonb) AS IMPLICIT;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME} || true || true
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE OR REPLACE FUNCTION text_to_jsonb(text) RETURNS jsonb AS ' SELECT \$1::json::jsonb; ' LANGUAGE SQL IMMUTABLE;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE CAST (text AS jsonb) WITH FUNCTION text_to_jsonb(text) AS IMPLICIT;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME} || true
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE OR REPLACE FUNCTION jsonb_to_text(jsonb) RETURNS text AS ' SELECT \$1::json::text; ' LANGUAGE SQL IMMUTABLE;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE CAST (jsonb AS text) WITH FUNCTION jsonb_to_text(jsonb) AS IMPLICIT;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME} || true

	# Creates ISO timestamp converstion function.
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE OR REPLACE FUNCTION CAST_ISO_TIMESTAMP(text) RETURNS timestamptz \
			LANGUAGE SQL IMMUTABLE AS \$\$SELECT TO_TIMESTAMP(\$1, 'YYYY-MM-DD\"T\"HH24:MI:SS.NS')\$\$;" \
		 -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}

# If the JSON has been (or should not) configured yet.
else

	${DEBUG} && echo "Skipping JSON cast"

fi

# If unaccent extension should be confgured.
${DEBUG} && echo "ENABLE_UNACCENT=${ENABLE_UNACCENT}"
if [ "${ENABLE_UNACCENT}" = "true" ] 
then

	${DEBUG} && echo "Configuring unaccent extension"

	# Creates unaccent extension.
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE EXTENSION IF NOT EXISTS unaccent;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE OR REPLACE FUNCTION immutable_unaccent(text) RETURNS text LANGUAGE SQL IMMUTABLE AS \$\$SELECT unaccent(\$1)\$\$;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}

	# Creates pg_trgm extension.
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}
	
# If unaccent extension should not be confgured.
else 

	${DEBUG} && echo "Skipping unaccent extension"

fi

# If tablefunc extension should be confgured.
${DEBUG} && echo "ENABLE_TABLEFUNC=${ENABLE_TABLEFUNC}"
if [ "${ENABLE_TABLEFUNC}" = "true" ] 
then

	${DEBUG} && echo "Configuring tablefunc extension"

	# Creates tablefunc extension.
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE EXTENSION IF NOT EXISTS tablefunc;" -U ${POSTGRES_ADMIN_USER} ${DATABASE_NAME}
	
# If unaccent extension should not be confgured.
else 

	${DEBUG} && echo "Skipping unaccent extension"

fi

# If the JSON has not been (and should) configured yet.
${DEBUG} && echo "REPLICATOR_POSTGRES_USER=${REPLICATOR_POSTGRES_USER}"
if [ ! -f "${REPLICATION_LOCK_FILE}" ] && [ "${REPLICATOR_POSTGRES_USER}" != "" ]
then
	
	${DEBUG} && echo "Configuring replication"

	# Also creates the replication user.
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE USER ${REPLICATOR_POSTGRES_USER} REPLICATION LOGIN ENCRYPTED PASSWORD '${REPLICATOR_POSTGRES_PASSWORD}';" -U ${POSTGRES_ADMIN_USER}

	# Creates the lock.
	touch ${REPLICATION_LOCK_FILE}
	
# If the JSON has been (or should not) configured yet.
else 

	${DEBUG} && echo "Skipping replication"

fi

# If there is a configuration file.
${DEBUG} && echo "SQL_CONFIGURATION=${SQL_CONFIGURATION}"
if [ -f "${SQL_CONFIGURATION}" ]
then
	
	${DEBUG} && echo "Configuring database"

	# Also creates the replication user.
	psql -a -f "${SQL_CONFIGURATION}" -U ${POSTGRES_USER} ${DATABASE_NAME}

# If there is no configuration file.
else 

	${DEBUG} && echo "Skipping database configuration"

fi








