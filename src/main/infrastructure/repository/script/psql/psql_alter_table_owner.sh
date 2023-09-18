#!/bin/sh

# Default parameters
DEBUG=${DEBUG:=true}

echo "[INFO] Initializing alter table owner..."
${DEBUG} && echo "POSTGRES_DEFAULT_USER=${POSTGRES_DEFAULT_USER}"
${DEBUG} && echo "POSTGRES_DEFAULT_DATABASE=$POSTGRES_DEFAULT_DATABASE"
# Initializing user/group variables
ALTER_OWNER_TABLE_SCHEMAS=$(env | grep "PSQL_ALTER_OWNER" | sed -e "s/PSQL_ALTER_OWNER=//")
if [ ! -z $ALTER_OWNER_TABLE_SCHEMAS ]; then
	ALTER_OWNER_TABLE_SCHEMAS=$( echo ${ALTER_OWNER_TABLE_SCHEMAS} | tr "[:upper:]" "[:lower:]" )
	ALTER_OWNER_TABLE_SCHEMAS=$( echo ${ALTER_OWNER_TABLE_SCHEMAS} | tr "," "\n" )
	for ALTER_OWNER_TABLE_SCHEMA in $ALTER_OWNER_TABLE_SCHEMAS; do
		${DEBUG} && echo "ALTER_OWNER_TABLE_SCHEMAS=${ALTER_OWNER_TABLE_SCHEMAS}"
		SCHEMA_TABLES=$(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -t -A -q -X -c "select tablename from pg_tables where schemaname='${ALTER_OWNER_TABLE_SCHEMA}';" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE} || true )
		for SCHEMA_TABLE in $SCHEMA_TABLES; do
			${DEBUG} && echo "[INFO] MOVING SCHEMA_TABLES=${SCHEMA_TABLES} to POSTGRES_DEFAULT_USER=${POSTGRES_DEFAULT_USER}"
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -t -A -q -X -c "ALTER TABLE ${ALTER_OWNER_TABLE_SCHEMA}.${SCHEMA_TABLE} OWNER TO ${POSTGRES_DEFAULT_USER};" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE} || true 
		done
	done
else
	echo "[INFO] Skipping alter table owner due conditional..."
fi

