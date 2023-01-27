#!/bin/sh

# Default parameters
DEBUG=${DEBUG:=true}
SKIP_DELETE=${SKIP_DELETE:=false}

# Initializing user/group variables
USER_READ_GROUP_VARS=$(env | grep "PSQL_READ_SCHEMA_" | sed -e "s/PSQL_READ_SCHEMA_//")
USER_GROUP_VARS=$(echo "${USER_READ_GROUP_VARS}")

REMOVE_USER() {
	CURRENT_USER=$1
	if [ "${CURRENT_USER}" != "${POSTGRES_ADMIN_USER}" ] && [ "${CURRENT_USER}" != "${POSTGRES_DEFAULT_USER}" ] && [ "${CURRENT_USER}" != "${POSTGRES_REPLICATOR_USER}" ] 
	then
		for SCHEMA in $(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -t -c "SELECT schema_name FROM information_schema.schemata;" -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} --quiet)
		do
			${DEBUG} && echo "Removing user ${CURRENT_USER} permissions"
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "REVOKE ALL ON DATABASE \"${POSTGRES_DEFAULT_DATABASE}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} || true
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "REVOKE ALL ON SCHEMA \"${SCHEMA}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} || true
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "REVOKE ALL PRIVILEGES ON DATABASE \"${POSTGRES_DEFAULT_DATABASE}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} || true
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "REVOKE ALL ON ALL TABLES IN SCHEMA \"${SCHEMA}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} || true
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "REVOKE ALL ON ALL SEQUENCES IN SCHEMA \"${SCHEMA}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} || true
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "REVOKE ALL ON ALL FUNCTIONS IN SCHEMA \"${SCHEMA}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} || true
			${DEBUG} && echo "Removing user ${CURRENT_USER}"
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -d ${POSTGRES_DEFAULT_DATABASE} -c "REASSIGN OWNED BY \"${CURRENT_USER}\" to \"${POSTGRES_DEFAULT_USER}\";" -U ${POSTGRES_ADMIN_USER}
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -d ${POSTGRES_DEFAULT_DATABASE} -c "DROP OWNED BY \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER}
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "DROP USER IF EXISTS \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} || true
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "DROP ROLE IF EXISTS \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} || true
		done
	fi
}

if ! ($SKIP_DELETE)
then
	for USER_GROUP_VAR in ${USER_GROUP_VARS} 
	do
		SCHEMA_USERS=
		USERS=
		USER_GROUPS=$( echo "${USER_GROUP_VAR}" | sed -e "s/.*=//" )
		USER_GROUP_SCHEMA=$( echo "${USER_GROUP_VAR}" | sed -e "s/=.*//" )
		USER_GROUP_SCHEMA=$( echo ${USER_GROUP_SCHEMA} | tr "[:upper:]" "[:lower:]" )
		SCHEMA_USERS=$(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -t -A -q -X -c "SELECT rolname from pg_namespace, pg_catalog.pg_roles WHERE array_to_string(nspacl,',') like '%'||rolname||'%' and nspname = '$USER_GROUP_SCHEMA';" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE} || true )
		${DEBUG} && echo "USER_GROUP_SCHEMA=${USER_GROUP_SCHEMA}"
		${DEBUG} && echo "USER_GROUPS=${USER_GROUPS}"
		USER_GROUPS=$( echo "${USER_GROUPS}" | sed -e "s/,/\n/g" )
		for USER_GROUP in ${USER_GROUPS} 
		do
			USERS="$(ldapsearch -LLL -w "${LDAP_PASSWORD}" -D "${LDAP_USER}" -h "${LDAP_HOST}" \
			-b "${LDAP_GROUPS}" "(cn=${USER_GROUP})" 	| grep memberUid | sed "s/memberUid: //g")\n$USERS"
		done
		USERS=$(echo $USERS | sort | uniq)
		${DEBUG} && echo SCHEMA_USERS: $SCHEMA_USERS
		${DEBUG} && echo LDAP_GROUP_USERS: $USERS
		for USER_DB in ${SCHEMA_USERS} 
		do
			if ! (echo $USERS  | grep -wq $USER_DB)
			then
				REMOVE_USER $USER_DB
			fi
		done
	done
else
	echo "Skiping remove user due conditional"
fi