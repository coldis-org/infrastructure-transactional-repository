#!/bin/sh

# Checks whether a running PostgreSQL deployment can be migrated to the version of this image,
# without deploying anything and without touching the deployment: the schema is read over the
# network, rebuilt in a throwaway cluster of the old version, and pg_upgrade --check is run
# against it. What it reports is what the migration would report, before a window is booked.
#
# It reads the catalog, which is where pg_upgrade --check looks: data types a later version
# dropped, extensions whose library this image does not carry, and so on. It cannot see what
# lives outside the catalog, so it is a pre-flight and not a guarantee.
#
#   PGPASSWORD=... ./psql_upgrade_check.sh <host> <port> <user>

# Default script behavior.
set -o errexit

# Default parameters.
CHECK_HOST=${1:?usage: psql_upgrade_check.sh <host> <port> <user>}
CHECK_PORT=${2:-5432}
CHECK_USER=${3:-postgres}
CHECK_DIR=$(mktemp -d /tmp/upgrade_check_XXXXXX)
NEW_VERSION=${PG_MAJOR}

# The version of the deployment tells which binaries rebuild its schema.
OLD_VERSION=$(psql -h ${CHECK_HOST} -p ${CHECK_PORT} -U ${CHECK_USER} -d postgres -At -c "SHOW server_version;" | cut -d. -f1)
OLD_BINDIR=/usr/lib/postgresql/${OLD_VERSION}/bin
NEW_BINDIR=/usr/lib/postgresql/${NEW_VERSION}/bin
if [ ! -x "${OLD_BINDIR}/pg_ctl" ]
then
	echo "ERROR: ${CHECK_HOST} runs PostgreSQL ${OLD_VERSION} and this image does not carry its binaries" >&2
	exit 1
fi
echo "Checking a PostgreSQL ${OLD_VERSION} deployment against PostgreSQL ${NEW_VERSION}"

# Both throwaway clusters have to carry the data checksum setting of the deployment, which is
# what the migration would have to match: pg_upgrade refuses to run when the two differ.
OLD_CHECKSUMS=$(psql -h ${CHECK_HOST} -p ${CHECK_PORT} -U ${CHECK_USER} -d postgres -At -c "SHOW data_checksums;")
if [ "${OLD_CHECKSUMS}" = "on" ]
then
	OLD_CHECKSUM_ARG=--data-checksums
	NEW_CHECKSUM_ARG=--data-checksums
else
	OLD_CHECKSUM_ARG=
	NEW_CHECKSUM_ARG=--no-data-checksums
fi

# Rebuilds the schema in a cluster of its own, which is what pg_upgrade reads. Only the schema
# is dumped: the checks look at the catalog, and the data would take as long as it is large.
chown postgres ${CHECK_DIR}
su postgres -c "${OLD_BINDIR}/initdb -D ${CHECK_DIR}/old -E UTF8 ${OLD_CHECKSUM_ARG}" > /dev/null 2>&1
su postgres -c "${OLD_BINDIR}/pg_ctl start -D ${CHECK_DIR}/old -w -o '-c listen_addresses= -c unix_socket_directories=/tmp -p 5499'" > /dev/null
# Roles are read without their passwords, which needs no superuser and keeps the hashes of the
# deployment out of a file on whatever machine this runs on. The throwaway cluster is only ever
# reached over a local socket, so the roles having no password there costs nothing.
echo "Reading the schema of ${CHECK_HOST}"
${OLD_BINDIR}/pg_dumpall -h ${CHECK_HOST} -p ${CHECK_PORT} -U ${CHECK_USER} --schema-only --no-role-passwords > ${CHECK_DIR}/schema.sql
su postgres -c "psql -h /tmp -p 5499 -d postgres -q -f ${CHECK_DIR}/schema.sql" > ${CHECK_DIR}/restore.log 2>&1 || true
su postgres -c "${OLD_BINDIR}/pg_ctl stop -D ${CHECK_DIR}/old -m fast -w" > /dev/null

# What the schema could not rebuild never reaches the catalog pg_upgrade reads, so a check run
# on it alone would report a cluster that migrates cleanly while the real one does not. The
# extensions of the deployment are therefore compared against the ones this image carries,
# which is the case the rebuild is least able to reproduce.
echo "Checking the extensions of ${CHECK_HOST} against PostgreSQL ${NEW_VERSION}"
MISSING=
CHECK_DATABASES=$(psql -h ${CHECK_HOST} -p ${CHECK_PORT} -U ${CHECK_USER} -d postgres -At -c "SELECT datname FROM pg_database WHERE datallowconn AND datname <> 'template0';")
for EXTENSION in $(for CHECK_DATABASE in ${CHECK_DATABASES}
	do
		psql -h ${CHECK_HOST} -p ${CHECK_PORT} -U ${CHECK_USER} -d ${CHECK_DATABASE} -At -c "SELECT extname FROM pg_extension;"
	done | sort -u)
do
	if [ ! -f "$(${NEW_BINDIR}/pg_config --sharedir)/extension/${EXTENSION}.control" ]
	then
		echo "  ${EXTENSION}: NOT in this image"
		MISSING=true
	fi
done
if [ -n "${MISSING}" ]
then
	echo "ERROR: the migration would fail on the extensions above — install them in the repository image of PostgreSQL ${NEW_VERSION}, or drop them before migrating" >&2
	exit 1
fi
echo "  every extension of the deployment is present"

# The rebuild dropping statements of its own also hides them from the check. The roles the
# throwaway cluster was initialized with are expected to collide with the dumped ones.
grep -i error ${CHECK_DIR}/restore.log | grep -v 'role .* already exists' | sort -u > ${CHECK_DIR}/restore_errors.log || true
if [ -s ${CHECK_DIR}/restore_errors.log ]
then
	echo "The schema did not rebuild cleanly, so the checks below cover less than the migration would:"
	head -20 ${CHECK_DIR}/restore_errors.log | sed -e 's/^/  /'
fi

# Runs the checks pg_upgrade would run at the start of the migration.
su postgres -c "${NEW_BINDIR}/initdb -D ${CHECK_DIR}/new -E UTF8 ${NEW_CHECKSUM_ARG}" > /dev/null 2>&1
su postgres -c "cd ${CHECK_DIR} && ${NEW_BINDIR}/pg_upgrade --check --old-bindir=${OLD_BINDIR} --new-bindir=${NEW_BINDIR} --old-datadir=${CHECK_DIR}/old --new-datadir=${CHECK_DIR}/new"
