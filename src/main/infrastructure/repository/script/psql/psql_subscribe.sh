#!/bin/sh

# Default script behavior.
set +e

# Default parameters.
DEBUG=true
SUB_NAME=${SUB_NAME:-upgrade_subscription}
PUB_NAME=${PUB_NAME:-upgrade_publication}
ENV_FILE="/local/application.env"

# Update environment variables
if [ -f "$ENV_FILE" ]; then
  . "$ENV_FILE"
fi

# Enables interruption signal handling.
trap - INT TERM

if [ $UPGRADE_SERVICE = "true" ]; then

	EXIST_PUB=$(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -At -h "${MASTER_ENDPOINT}" -p "${MASTER_PORT}" -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} -c "SELECT 1 FROM pg_publication WHERE pubname='${PUB_NAME}'" )
	
	# Remotely creating publisher
	if [ "${EXIST_PUB:-0}" -eq 0 ]; then
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD:=postgres} psql -h "${MASTER_ENDPOINT}" -p "${MASTER_PORT}" -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE}  -c "CREATE PUBLICATION upgrade_publication FOR ALL TABLES;" || true
		echo "waiting 15s"
		sleep 15
		# Check again
		EXIST_PUB=$(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -At -h "${MASTER_ENDPOINT}" -p "${MASTER_PORT}" -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} -c "SELECT 1 FROM pg_publication WHERE pubname='${PUB_NAME}'" )
  	fi

	# if no publication exists on master
	if [ "${EXIST_PUB:-0}" -eq 0 ]; then
    	echo "Exiting... Publication '${PUB_NAME}' does not exists on $MASTER_ENDPOINT:$MASTER_PORT/$POSTGRES_DEFAULT_DATABASE"
    	kill -s TERM 1 
  	fi

	EXIST_SUB=$(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -At -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} -c "SELECT 1 AS sub_exists FROM pg_subscription WHERE subname = '$SUB_NAME'")
	if [ "${EXIST_SUB:-0}" -eq 0 ]; then
		echo "Creating subcription ${SUB_NAME}"

		# Get schema 
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} pg_dump -h ${MASTER_ENDPOINT} -p ${MASTER_PORT} -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} --schema-only > /tmp/schema.sql
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} -f /tmp/schema.sql

		# Create subscription
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} -c "CREATE SUBSCRIPTION ${SUB_NAME} CONNECTION 'host=${MASTER_ENDPOINT} port=${MASTER_PORT} dbname=${POSTGRES_DEFAULT_DATABASE} user=${POSTGRES_ADMIN_USER} password=${POSTGRES_ADMIN_PASSWORD}' PUBLICATION ${PUB_NAME} WITH (copy_data = true, create_slot = true, enabled = true);"
	else
		${DEBUG} && echo "Subscription ${SUB_NAME} already exists - Trying to update connection"
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} -c "ALTER SUBSCRIPTION ${SUB_NAME} CONNECTION 'host=${MASTER_ENDPOINT} port=${MASTER_PORT} dbname=${POSTGRES_DEFAULT_DATABASE} user=${POSTGRES_ADMIN_USER} password=${POSTGRES_ADMIN_PASSWORD}';"
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} -c "ALTER SUBSCRIPTION ${SUB_NAME} REFRESH PUBLICATION WITH (copy_data = true);"
	fi
else
	${DEBUG} && echo "Creating publication"
	PGPASSWORD=${POSTGRES_ADMIN_PASSWORD:=postgres} psql -c "CREATE PUBLICATION upgrade_publication FOR ALL TABLES;" -U ${POSTGRES_ADMIN_USER} || true
fi
