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
STATS_LOCK_FILE="${PGDATA}/stats_configured.lock"

# Enables interruption signal handling.
trap - INT TERM

# Waits until database is available.
while !(PGPASSWORD=${POSTGRES_PASSWORD} psql -c 'SELECT 1;' -v ON_ERROR_STOP=1 -U ${POSTGRES_USER})
do
	echo "Waiting database initialization"		
	sleep 10
done

# Makes sure configuration is updated
${DEBUG} && echo "Updating configuration"
rm -Rf ${PGDATA}/postgresql.conf
cp /tmp/postgresql.conf ${PGDATA}/postgresql.conf
rm -Rf ${PGDATA}/pg_hba.conf
cp /tmp/pg_hba.conf ${PGDATA}/pg_hba.conf
PGPASSWORD=${POSTGRES_PASSWORD} psql -c "SELECT pg_reload_conf();" -U ${POSTGRES_USER}

# If the user has not been (and should) configured yet.
${DEBUG} && echo "USER_NAME=${USER_NAME}"
if [ ! -f ${USER_LOCK_FILE} ] && [ "${USER_NAME}" != "" ] 
then

	${DEBUG} && echo "Configuring default database"
	
	# Creates the default user.
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE USER ${USER_NAME} WITH PASSWORD '${USER_PASSWORD}';" -U ${POSTGRES_USER}
	
	# Creates the default database.
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE DATABASE ${DATABASE_NAME} OWNER ${USER_NAME};" -U ${POSTGRES_USER}

	# Creates the lock.
	touch ${USER_LOCK_FILE}
	
# If the user has been (or should not) configured yet.
else

	${DEBUG} && echo "Skipping default database"
	
fi


# If stats extension should be confgured.
${DEBUG} && echo "ENABLE_STATS=${ENABLE_STATS}"
if [ ! -f ${STATS_LOCK_FILE} ] && [ "${ENABLE_STATS}" != "false" ] 
then

	${DEBUG} && echo "Configuring stats extension"

	# Creates pg_trgm extension.
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	
	# Creates the lock.
	touch ${STATS_LOCK_FILE}
	
# If stats extension should not be confgured.
else 

	${DEBUG} && echo "Skipping stats extension"

fi


# If the JSON has not been (and should) configured yet.
${DEBUG} && echo "ENABLE_JSON_CAST=${ENABLE_JSON_CAST}"
if [ ! -f ${JSON_CAST_LOCK_FILE} ] && [ "${ENABLE_JSON_CAST}" = "true" ] 
then

	${DEBUG} && echo "Configuring JSON cast"

	# Creates the JSON casts.
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE CAST (varchar as json) WITHOUT FUNCTION AS IMPLICIT;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE CAST (json as varchar) WITHOUT FUNCTION AS IMPLICIT;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE FUNCTION varchar_to_jsonb(varchar) RETURNS jsonb AS ' SELECT \$1::json::jsonb; ' LANGUAGE SQL IMMUTABLE;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE CAST (varchar AS jsonb) WITH FUNCTION varchar_to_jsonb(varchar) AS IMPLICIT;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE FUNCTION jsonb_to_varchar(jsonb) RETURNS varchar AS ' SELECT \$1::json::varchar; ' LANGUAGE SQL IMMUTABLE;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE CAST (jsonb AS varchar) WITH FUNCTION jsonb_to_varchar(jsonb) AS IMPLICIT;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE FUNCTION text_to_jsonb(text) RETURNS jsonb AS ' SELECT \$1::json::jsonb; ' LANGUAGE SQL IMMUTABLE;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE CAST (text AS jsonb) WITH FUNCTION text_to_jsonb(text) AS IMPLICIT;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE FUNCTION jsonb_to_text(jsonb) RETURNS text AS ' SELECT \$1::json::text; ' LANGUAGE SQL IMMUTABLE;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE CAST (jsonb AS text) WITH FUNCTION jsonb_to_text(jsonb) AS IMPLICIT;" -U ${POSTGRES_USER} ${DATABASE_NAME}

	# Creates ISO timestamp converstion function.
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE OR REPLACE FUNCTION CAST_ISO_TIMESTAMP(text) RETURNS timestamptz \
			LANGUAGE SQL IMMUTABLE AS \$\$SELECT TO_TIMESTAMP(\$1, 'YYYY-MM-DD\"T\"HH24:MI:SS.US')\$\$;" \
		 -U ${POSTGRES_USER} ${DATABASE_NAME}

	# Creates the lock.
	touch ${JSON_CAST_LOCK_FILE}
	
# If the JSON has been (or should not) configured yet.
else

	${DEBUG} && echo "Skipping JSON cast"

fi

# If unaccent extension should be confgured.
${DEBUG} && echo "ENABLE_UNACCENT=${ENABLE_UNACCENT}"
if [ ! -f ${UNACCENT_LOCK_FILE} ] && [ "${ENABLE_UNACCENT}" = "true" ] 
then

	${DEBUG} && echo "Configuring unaccent extension"

	# Creates unaccent extension.
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE EXTENSION IF NOT EXISTS unaccent;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE OR REPLACE FUNCTION immutable_unaccent(text) RETURNS text LANGUAGE SQL IMMUTABLE AS \$\$SELECT unaccent(\$1)\$\$;" -U ${POSTGRES_USER} ${DATABASE_NAME}

	# Creates pg_trgm extension.
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" -U ${POSTGRES_USER} ${DATABASE_NAME}
	
	# Creates the lock.
	touch ${UNACCENT_LOCK_FILE}
	
# If unaccent extension should not be confgured.
else 

	${DEBUG} && echo "Skipping unaccent extension"

fi

# If the JSON has not been (and should) configured yet.
${DEBUG} && echo "REPLICATOR_USER_NAME=${REPLICATOR_USER_NAME}"
if [ ! -f ${REPLICATION_LOCK_FILE} ] && [ "${REPLICATOR_USER_NAME}" != "" ]
then
	
	${DEBUG} && echo "Configuring replication"

	# Also creates the replication user.
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE USER ${REPLICATOR_USER_NAME} REPLICATION LOGIN ENCRYPTED PASSWORD '${REPLICATOR_USER_PASSWORD}';" -U ${POSTGRES_USER}

	# Creates the lock.
	touch ${REPLICATION_LOCK_FILE}
	
# If the JSON has been (or should not) configured yet.
else 

	${DEBUG} && echo "Skipping replication"

fi

# If there is a configuration file.
${DEBUG} && echo "SQL_CONFIGURATION=${SQL_CONFIGURATION}"
if [ -f ${SQL_CONFIGURATION} ]
then
	
	${DEBUG} && echo "Configuring database"

	# Also creates the replication user.
	psql -a -f ${SQL_CONFIGURATION} -U ${USER_NAME} ${DATABASE_NAME} 

# If there is no configuration file.
else 

	${DEBUG} && echo "Skipping database configuration"

fi

# If there is an extra read users group.
${DEBUG} && echo "READ_USERS_GROUP=${READ_USERS_GROUP}"
if [ ! -z "${READ_USERS_GROUP}" ]
then

	${DEBUG} && echo "Getting read users from ldap: ${READ_USERS_GROUP}"
	READ_USERS=$(ldapsearch -LLL -w "${LDAP_PASSWORD}" -D "${LDAP_USER}" \
	-h "${LDAP_HOST}" -b "${LDAP_BASE}" "(cn=${READ_USERS_GROUP})" \
	 | grep memberUid | sed "s/memberUid: //g")

fi

# For each extra read users.
${DEBUG} && echo "READ_USERS=${READ_USERS}"
for READ_USER in $(echo ${READ_USERS} | sed "s/,/ /g")
do

	# Configuring extra write user.
	${DEBUG} && echo "Configuring extra read user ${READ_USER}"
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON TABLES FROM \"${READ_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON SEQUENCES FROM \"${READ_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON FUNCTIONS FROM \"${READ_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "REVOKE ALL ON SCHEMA \"public\" FROM \"${READ_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "REVOKE ALL ON DATABASE \"${DATABASE_NAME}\" FROM \"${READ_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON SCHEMA \"public\" FROM \"${READ_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON DATABASE \"${DATABASE_NAME}\" FROM \"${READ_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON ALL TABLES IN SCHEMA \"public\" FROM \"${READ_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON ALL SEQUENCES IN SCHEMA \"public\" FROM \"${READ_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON ALL FUNCTIONS IN SCHEMA \"public\" FROM \"${READ_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "DROP USER IF EXISTS \"${READ_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "DROP ROLE IF EXISTS \"${READ_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE USER \"${READ_USER}\" WITH NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN NOREPLICATION;" -U ${POSTGRES_PASSWORD} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT CONNECT ON DATABASE \"${DATABASE_NAME}\" TO \"${READ_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT USAGE ON SCHEMA \"public\" TO \"${READ_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT SELECT ON ALL TABLES IN SCHEMA \"public\" TO \"${READ_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT SELECT ON ALL SEQUENCES IN SCHEMA \"public\" TO \"${READ_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA \"public\" TO \"${READ_USER}\";" -U ${USER_NAME} || true

done

# If there is an extra write users group.
${DEBUG} && echo "WRITE_USERS_GROUP=${WRITE_USERS_GROUP}"
if [ ! -z "${WRITE_USERS_GROUP}" ]
then

	${DEBUG} && echo "Getting write users from ldap: ${WRITE_USERS_GROUP}"
	WRITE_USERS=$(ldapsearch -LLL -w "${LDAP_PASSWORD}" -D "${LDAP_USER}" \
	-h "${LDAP_HOST}" -b "${LDAP_BASE}" "(cn=${WRITE_USERS_GROUP})" \
	 | grep memberUid | sed "s/memberUid: //g")

fi

# For each extra write users.
${DEBUG} && echo "WRITE_USERS=${WRITE_USERS}"
for WRITE_USER in $(echo ${WRITE_USERS} | sed "s/,/ /g")
do

	# Configuring extra write user.
	${DEBUG} && echo "Configuring extra write user ${WRITE_USER}"
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON TABLES FROM \"${WRITE_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON SEQUENCES FROM \"${WRITE_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "ALTER DEFAULT PRIVILEGES IN SCHEMA \"public\" REVOKE ALL ON FUNCTIONS FROM \"${WRITE_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "REVOKE ALL ON SCHEMA \"public\" FROM \"${WRITE_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "REVOKE ALL ON DATABASE \"${DATABASE_NAME}\" FROM \"${WRITE_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON SCHEMA \"public\" FROM \"${WRITE_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON DATABASE \"${DATABASE_NAME}\" FROM \"${WRITE_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON ALL TABLES IN SCHEMA \"public\" FROM \"${WRITE_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON ALL SEQUENCES IN SCHEMA \"public\" FROM \"${WRITE_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "REVOKE ALL ON ALL FUNCTIONS IN SCHEMA \"public\" FROM \"${WRITE_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "DROP USER IF EXISTS \"${WRITE_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "DROP ROLE IF EXISTS \"${WRITE_USER}\";" -U ${POSTGRES_USER} || true
	PGPASSWORD=${POSTGRES_PASSWORD} psql -c "CREATE USER \"${WRITE_USER}\" WITH NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN NOREPLICATION;" -U ${POSTGRES_PASSWORD} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT CONNECT ON DATABASE \"${DATABASE_NAME}\" TO \"${WRITE_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT USAGE ON SCHEMA \"public\" TO \"${WRITE_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT ALL ON ALL TABLES IN SCHEMA \"public\" TO \"${WRITE_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT ALL ON ALL SEQUENCES IN SCHEMA \"public\" TO \"${WRITE_USER}\";" -U ${USER_NAME} || true
	PGPASSWORD=${USER_PASSWORD} psql -c "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA \"public\" TO \"${WRITE_USER}\";" -U ${USER_NAME} || true

done


