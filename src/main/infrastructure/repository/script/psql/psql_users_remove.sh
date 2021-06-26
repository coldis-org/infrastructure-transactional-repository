#!/bin/sh

# If there ldap users are provided.
${DEBUG} && echo "LDAP_USERS=${LDAP_USERS}"
if [ ! -z "${LDAP_USERS}" ]
then

	${DEBUG} && echo "Getting all users from ldap: ${READ_USERS_GROUP}"
	ALL_LDAP_USERS=$(ldapsearch -LLL -w "${LDAP_PASSWORD}" -D "${LDAP_USER}" \
	-h "${LDAP_HOST}" -b "${LDAP_USERS}" \
	| grep cn: | sed "s/cn: //g")

fi

# For each user.
${DEBUG} && echo "ALL_LDAP_USERS=${ALL_LDAP_USERS}"
for CURRENT_USER in ${ALL_LDAP_USERS}
do

	# If not the admin or main user.
	if [ "${CURRENT_USER}" != "${POSTGRES_PASSWORD}" ] && [ "${CURRENT_USER}" != "${POSTGRES_PASSWORD}" ]
	then
	
		# For each schema.
		for SCHEMA in $(PGPASSWORD=${POSTGRES_PASSWORD} psql -c -t "SELECT schema_name FROM information_schema.schemata;" -U ${POSTGRES_USER} --quiet)
		do
		
			# Removing user.
			${DEBUG} && echo "Removing user ${CURRENT_USER} permissions"
			PGPASSWORD=${POSTGRES_PASSWORD} psql -c "REVOKE ALL ON DATABASE \"${POSTGRES_DEFAULT_DATABASE}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_USER} || true
			PGPASSWORD=${POSTGRES_PASSWORD} psql -c "REVOKE ALL ON SCHEMA \"${SCHEMA}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_USER} || true
			PGPASSWORD=${POSTGRES_PASSWORD} psql -c "REVOKE ALL ON ALL TABLES IN SCHEMA \"${SCHEMA}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_USER} || true
			PGPASSWORD=${POSTGRES_PASSWORD} psql -c "REVOKE ALL ON ALL SEQUENCES IN SCHEMA \"${SCHEMA}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_USER} || true
			PGPASSWORD=${POSTGRES_PASSWORD} psql -c "REVOKE ALL ON ALL FUNCTIONS IN SCHEMA \"${SCHEMA}\" FROM \"${CURRENT_USER}\";" -U ${POSTGRES_USER} || true
			${DEBUG} && echo "Removing user ${CURRENT_USER}"
			PGPASSWORD=${POSTGRES_PASSWORD} psql -c "DROP USER IF EXISTS \"${CURRENT_USER}\";" -U ${POSTGRES_USER} || true
			PGPASSWORD=${POSTGRES_PASSWORD} psql -c "DROP ROLE IF EXISTS \"${CURRENT_USER}\";" -U ${POSTGRES_USER} || true
		
		done
	
	fi

done
