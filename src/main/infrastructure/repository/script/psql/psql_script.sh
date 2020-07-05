#!/bin/sh


# Executes the script.
echo "Starting script"
COMMAND="$@"
echo ${USER_PASSWORD} | exec psql -c "${COMMAND}" -h ${DATABASE_HOST} -d ${DATABASE_NAME} -U ${USER_NAME} -W
echo "Ending script"
