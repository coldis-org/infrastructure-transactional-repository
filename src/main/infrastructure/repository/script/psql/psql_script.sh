#!/bin/sh


# Executes the script.
echo "Starting script"
COMMAND="$@"
echo ${POSTGRES_DEFAULT_PASSWORD} | exec psql -c "${COMMAND}" -h ${DATABASE_HOST} -d ${POSTGRES_DEFAULT_DATABASE} -U ${POSTGRES_DEFAULT_USER} -W
echo "Ending script"
