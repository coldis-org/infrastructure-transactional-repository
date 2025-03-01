#!/bin/sh

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true
DEBUG_OPT=
REPLICATION_LOCK_FILE=${PGDATA}/replication_configured.lock
SKIP_RELOAD=false

# For each argument.
while :; do
	case ${1} in
		
		# Debug argument.
		--debug)
			DEBUG=true
			DEBUG_OPT="--debug"
			;;
			
		# If actual reload should be done.
		--skip-reload)
			SKIP_RELOAD=true
			;;
			
		# No more options.
		*)
			break

	esac 
	shift
done


# Enables interruption signal handling.
trap - INT TERM

CHECK_MASTER_CONN () {
  MASTER_CONN=$(cat ${PGDATA}/postgresql.auto.conf)
  MASTER_HOST_CONN=$(echo "$MASTER_CONN" | grep -o 'host=[^ ]*' | cut -d'=' -f2)
  MASTER_PORT_CONN=$(echo "$MASTER_CONN" | grep -o 'port=[^ ]*' | cut -d'=' -f2)

  if [ "$MASTER_HOST_CONN" != "$MASTER_ENDPOINT" -o "$MASTER_PORT_CONN" != "$COPY_PORT" ]; then
    sed -i "s/host=$MASTER_HOST_CONN/host=$MASTER_ENDPOINT/g;
    	s/port=$MASTER_PORT_CONN/port=$COPY_PORT/g" ${PGDATA}/postgresql.auto.conf
	echo "UPDATING MASTER_CONN=${MASTER_ENDPOINT} - MASTER_PORT=${COPY_PORT}"
  fi
}

CHECK_LDAP_CONN () {
  PG_HBA=$(cat ${PGDATA}/pg_hba.conf)
  LDAP_HOST_FILE=$(echo "$PG_HBA" | grep -o 'ldapserver=[^ ]*' | head -n 1 | cut -d'=' -f2 | tr -d '"')
  LDAP_PORT_FILE=$(echo "$PG_HBA" | grep -o 'ldapport=[^ ]*' | head -n 1 | cut -d'=' -f2 | tr -d '"')

  if [ "$LDAP_HOST_FILE" != "$LDAP_DB_URI" -o "$LDAP_PORT_FILE" != "$LDAP_DB_PORT" ]; then

    sed -i "s/ldapserver=\"$LDAP_HOST_FILE\"/ldapserver=\"$LDAP_DB_URI\"/g;
      s/ldapport=\"$LDAP_PORT_FILE\"/ldapport=\"$LDAP_DB_PORT\"/g" ${PGDATA}/pg_hba.conf
	echo "UPDATING LDAP_CONN=${LDAP_DB_URI} - LDAP_PORT=${LDAP_DB_PORT}"
  fi
}

  RELOAD_PG_CONF (){
    echo "Reloading configuration"
    PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "SELECT pg_reload_conf();" -U ${POSTGRES_ADMIN_USER} || true
  }

if [ -f ${REPLICATION_LOCK_FILE} ]; then
	CHECK_MASTER_CONN
	CHECK_LDAP_CONN
  
  if [ $SKIP_RELOAD != "true" ];  then
    RELOAD_PG_CONF
  else
    echo "Skiping reload configuration"
  fi
fi
