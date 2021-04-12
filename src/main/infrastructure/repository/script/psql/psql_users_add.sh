#!/bin/sh


# For each permission.
USER_READ_GROUP_VARS=$(env | grep "PSQL_READ_SCHEMA_" | sed -e "s/PSQL_READ_SCHEMA_/read|/" -e "s/_TABLE_/|/")
USER_WRITE_GROUP_VARS=$(env | grep "PSQL_WRITE_SCHEMA_" | sed -e "s/PSQL_WRITE_SCHEMA_/write|/" -e "s/_TABLE_/|/")
USER_GROUP_VARS=$(echo "${USER_READ_GROUP_VARS}\n${USER_WRITE_GROUP_VARS}")
for USER_GROUP_VAR in ${USER_GROUP_VARS}
do

	# Gets the group variables.
	USER_GROUP_PROC_VAR=${USER_GROUP_VAR}
	USER_GROUP=$(echo "${USER_GROUP_PROC_VAR}" | sed -e "s/.*=//")
	USER_GROUP_PROC_VAR=$(echo "${USER_GROUP_PROC_VAR}" | sed -e "s/=${USER_GROUP}//")
	USER_GROUP_PERMISSION=$(echo "${USER_GROUP_PROC_VAR}" | sed -e "s/|.*//")
	USER_GROUP_PROC_VAR=$(echo "${USER_GROUP_PROC_VAR}" | sed -e "s/${USER_GROUP_PERMISSION}|//")
	USER_GROUP_SCHEMA=$(echo "${USER_GROUP_PROC_VAR}" | sed -e "s/|.*//")
	USER_GROUP_PROC_VAR=$(echo "${USER_GROUP_PROC_VAR}" | sed -e "s/${USER_GROUP_SCHEMA}|\?//")
	USER_GROUP_TABLE=$(echo "${USER_GROUP_PROC_VAR}")
	
	# Prepares the group variables.
	USER_GROUP_SCHEMA=$(echo ${USER_GROUP_SCHEMA} | tr "[:upper:]" "[:lower:]")
	USER_GROUP_TABLE=$(echo ${USER_GROUP_TABLE} | tr "[:upper:]" "[:lower:]")
	USER_GROUP_PERMISSION_GRANT=$([ "write" = ${USER_GROUP_PERMISSION} ] && echo "ALL")
	${DEBUG} && echo "USER_GROUP_PERMISSION=${USER_GROUP_PERMISSION}"
	${DEBUG} && echo "USER_GROUP_SCHEMA=${USER_GROUP_SCHEMA}"
	${DEBUG} && echo "USER_GROUP_TABLE=${USER_GROUP_TABLE}"
	${DEBUG} && echo "USER_GROUP=${USER_GROUP}"
	
	# Gets the users to configure permission.
	if [ ! -z "${USER_GROUP}" ]
	then
		${DEBUG} && echo "Getting read users from ldap: ${READ_USERS_GROUP}"
		USERS=$(ldapsearch -LLL -w "${LDAP_PASSWORD}" -D "${LDAP_USER}" \
		-h "${LDAP_HOST}" -b "${LDAP_GROUPS}" "(cn=${USER_GROUP})" \
		 | grep memberUid | sed "s/memberUid: //g")
	fi

	# For each user to configure access.
	for CURRENT_USER in ${USERS}
	do
	
		# Configures the user permissions.
		${DEBUG} && echo "Creating user ${CURRENT_USER}"
		echo PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE USER \"${USER}\" WITH NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN NOREPLICATION;" -U ${POSTGRES_ADMIN_PASSWORD} || true
		${DEBUG} && echo "Configuring permissions for user ${CURRENT_USER}"
		echo PGPASSWORD=${POSTGRES_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-CONNECT, TEMPORARY} ON DATABASE \"${DATABASE_NAME}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_USER}
		echo PGPASSWORD=${POSTGRES_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-USAGE} ON SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_USER}
		echo PGPASSWORD=${POSTGRES_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-SELECT} ON ${USER_GROUP_TABLE:-ALL TABLES} IN SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_USER}
		echo PGPASSWORD=${POSTGRES_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-SELECT} ON ALL SEQUENCES IN SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_USER}
		echo PGPASSWORD=${POSTGRES_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-EXECUTE} ON ALL FUNCTIONS IN SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_USER}
	
	done

done


