#!/bin/sh

# Default parameters.
DEBUG=${DEBUG:=true}
SKIP_ALTER_GROUP=${SKIP_ALTER_GROUP:=true}

# If not exist
if [ -z "$LDAP_HOST" ]; then
	${DEBUG} && echo MOUNTING LDAP_HOST VAR - ${LDAP_URI}:${LDAP_PORT}
	LDAP_HOST=${LDAP_URI}:${LDAP_PORT}
fi

# For each group to alter users.
USER_ALTER_GROUP_VARS=$(env | grep "PSQL_ALTER_GROUP_" | sed -e "s/PSQL_ALTER_GROUP_//")

ADD_USER_TO_GROUP() {
	CURRENT_USER=$1
	CURRENT_GROUP=$2
	if [ "${CURRENT_USER}" != "${POSTGRES_ADMIN_USER}" ] && [ "${CURRENT_USER}" != "${POSTGRES_DEFAULT_USER}" ] && [ "${CURRENT_USER}" != "${POSTGRES_REPLICATOR_USER}" ] 
	then
		${DEBUG} && echo "+ Inserting USER: ${CURRENT_USER} to GROUP: ${CURRENT_GROUP}"
		PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -t -A -q -X -c "ALTER GROUP \"${CURRENT_GROUP}\" ADD USER \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE} || true 
	fi
}

if ! ($SKIP_ALTER_GROUP) 
then
	for USER_ALTER_GROUP_VAR in ${USER_ALTER_GROUP_VARS}
	do
		USERS=
		GROUP_DATABASE_USERS=
		# Gets the group variables.
		USER_GROUPS=$(echo "${USER_ALTER_GROUP_VAR}" | sed -e "s/.*=//" | sed -e "s/,/\n/g")
		USER_ALTER_DATABASE_GROUP=$(echo "${USER_ALTER_GROUP_VAR}" | sed -e "s/=.*//" | tr "[:upper:]" "[:lower:]")
		${DEBUG} && echo "+ USER_ALTER_DATABASE_GROUP=${USER_ALTER_DATABASE_GROUP}"
		${DEBUG} && echo "+ USER_GROUPS=${USER_GROUPS}"
		# Get all users from all groups
		for USER_GROUP in ${USER_GROUPS} 
		do
			USERS="$(ldapsearch -LLL -w "${LDAP_PASSWORD}" -D "${LDAP_USER}" -H "ldap://${LDAP_HOST}" \
			-b "${LDAP_GROUPS}" "(cn=${USER_GROUP})" | grep memberUid | sed "s/memberUid: //g")\n$USERS"
		done
		USERS=$(echo $USERS | sort | uniq)
		GROUP_DATABASE_USERS=$(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -t -A -q -X -c "SELECT r.rolname FROM pg_catalog.pg_roles r LEFT JOIN pg_catalog.pg_auth_members pam ON (pam.member = r.oid) LEFT JOIN pg_roles pr ON (pam.roleid=pr.oid) WHERE r.rolcanlogin and pr.rolname = '$USER_ALTER_DATABASE_GROUP';" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE} || true )
		${DEBUG} && echo "+ USERS_FROM_LDAP=${USERS}"
		${DEBUG} && echo "+ USERS_FROM_DATABASE=${GROUP_DATABASE_USERS}"
		for USER in ${USERS} 
		do
			if ! (echo $GROUP_DATABASE_USERS | grep -wq $USER)
			then
				ADD_USER_TO_GROUP $USER $USER_ALTER_DATABASE_GROUP
			fi
		done
	done
else
	echo "+ Skiping alter user group due conditional"
fi
