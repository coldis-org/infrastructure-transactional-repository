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
CHECK_SOCKET_DIR=${CHECK_DIR}/socket
CHECK_CLUSTER_PORT=5499
NEW_VERSION=${PG_MAJOR}

# The working directory holds two clusters and a dump of the schema, and one of those clusters
# is running for part of the run. Every path out of here stops it before the directory goes:
# deleting a data directory under a live postmaster leaves it holding the port, and the next
# run of this then fails on something that has nothing to do with the deployment it checks.
upgrade_check_clean_up() {
	if [ -n "${OLD_BINDIR}" ] && [ -d "${CHECK_DIR}/old" ]
	then
		su postgres -c "${OLD_BINDIR}/pg_ctl stop -D ${CHECK_DIR}/old -m immediate -w" > /dev/null 2>&1 || true
	fi
	rm -rf "${CHECK_DIR}"
}
OLD_BINDIR=
trap upgrade_check_clean_up EXIT
trap 'upgrade_check_clean_up; exit 130' INT
trap 'upgrade_check_clean_up; exit 143' TERM

# The version of the deployment tells which binaries rebuild its schema. Taken without a pipe,
# so the exit status is psql's: behind one it is cut's, and a refused connection left the
# version empty and was reported below as a missing binary — sending the operator after a
# package when the password, the port or the host is what is wrong.
# The failure is tolerated so the message below is reached: under errexit the assignment alone
# would end the script on psql's exit status, leaving the operator psql's own line and nothing
# saying what to do with it.
CHECK_SERVER_VERSION=$(psql -h ${CHECK_HOST} -p ${CHECK_PORT} -U ${CHECK_USER} -d postgres -At -c "SHOW server_version;") || CHECK_SERVER_VERSION=
if [ -z "${CHECK_SERVER_VERSION}" ]
then
	echo "ERROR: ${CHECK_HOST}:${CHECK_PORT} did not answer as ${CHECK_USER} — check the host, the port, the user and PGPASSWORD" >&2
	exit 1
fi
OLD_VERSION=${CHECK_SERVER_VERSION%%.*}
# Checked before it builds the path to the binaries that are run, the way psql_upgrade.sh checks
# the version it reads off the volume: it reaches the command string of a su, and it comes from
# whatever answered on the host given on the command line.
case "${OLD_VERSION}" in
	''|*[!0-9]*)
		echo "ERROR: ${CHECK_HOST}:${CHECK_PORT} reported '${CHECK_SERVER_VERSION}' as its version, which does not start with a major version" >&2
		exit 1
		;;
esac
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
	# Turning checksums off is only an option from PostgreSQL 18 on, where they became the
	# default; before that initdb leaves them off and has no flag to ask for it. Both throwaway
	# clusters need the probe: a source already on 18 would otherwise get a checksummed old
	# cluster and an unchecksummed new one, and pg_upgrade --check refuses that pair — reporting
	# that a deployment cannot migrate when it migrates cleanly.
	if ${OLD_BINDIR}/initdb --help | grep -q -- --no-data-checksums
	then
		OLD_CHECKSUM_ARG=--no-data-checksums
	else
		OLD_CHECKSUM_ARG=
	fi
	if ${NEW_BINDIR}/initdb --help | grep -q -- --no-data-checksums
	then
		NEW_CHECKSUM_ARG=--no-data-checksums
	else
		NEW_CHECKSUM_ARG=
	fi
fi

# Rebuilds the schema in a cluster of its own, which is what pg_upgrade reads. Only the schema
# is dumped: the checks look at the catalog, and the data would take as long as it is large.
chown postgres ${CHECK_DIR}
# The cluster trusts local connections, so its socket lives in a directory of its own rather
# than in /tmp, which any process in the container can write to. It holds the deployment's
# whole schema and its role list.
mkdir -p "${CHECK_SOCKET_DIR}"
chown postgres:postgres "${CHECK_SOCKET_DIR}"
chmod 700 "${CHECK_SOCKET_DIR}"
su postgres -c "${OLD_BINDIR}/initdb -D ${CHECK_DIR}/old -E UTF8 ${OLD_CHECKSUM_ARG}" > /dev/null
su postgres -c "${OLD_BINDIR}/pg_ctl start -D ${CHECK_DIR}/old -w -o '-c listen_addresses= -c unix_socket_directories=${CHECK_SOCKET_DIR} -p ${CHECK_CLUSTER_PORT}'" > /dev/null
# Roles are read without their passwords, which needs no superuser and keeps the hashes of the
# deployment out of a file on whatever machine this runs on. The throwaway cluster is only ever
# reached over a local socket, so the roles having no password there costs nothing.
echo "Reading the schema of ${CHECK_HOST}"
${OLD_BINDIR}/pg_dumpall -h ${CHECK_HOST} -p ${CHECK_PORT} -U ${CHECK_USER} --schema-only --no-role-passwords > ${CHECK_DIR}/schema.sql
# Under the C locale, so the errors below can be recognized: this image runs in pt_BR and the
# server ships the translated catalogs, which would leave the filter matching nothing and the
# rebuild reported as clean.
su postgres -c "LC_ALL=C PGOPTIONS='-c lc_messages=C' psql -h ${CHECK_SOCKET_DIR} -p ${CHECK_CLUSTER_PORT} -d postgres -q -f ${CHECK_DIR}/schema.sql" > ${CHECK_DIR}/restore.log 2>&1 || true
su postgres -c "${OLD_BINDIR}/pg_ctl stop -D ${CHECK_DIR}/old -m fast -w" > /dev/null

# What the schema could not rebuild never reaches the catalog pg_upgrade reads, so a check run
# on it alone would report a cluster that migrates cleanly while the real one does not. The
# extensions of the deployment are therefore compared against the ones this image carries,
# which is the case the rebuild is least able to reproduce.
echo "Checking the extensions of ${CHECK_HOST} against PostgreSQL ${NEW_VERSION}"
HAS_MISSING_EXTENSION=
CHECK_DATABASES=$(psql -h ${CHECK_HOST} -p ${CHECK_PORT} -U ${CHECK_USER} -d postgres -At -c "SELECT datname FROM pg_database WHERE datallowconn AND datname <> 'template0';")
# Collected into a variable rather than read straight into the for: errexit does not reach a
# command substitution used as a word list, so a database whose catalog cannot be read would
# contribute nothing and the run would report every extension present.
CHECK_EXTENSIONS=
for CHECK_DATABASE in ${CHECK_DATABASES}
do
	CHECK_DATABASE_EXTENSIONS=$(psql -h ${CHECK_HOST} -p ${CHECK_PORT} -U ${CHECK_USER} -d ${CHECK_DATABASE} -At -c "SELECT extname FROM pg_extension;") || {
		echo "ERROR: could not read the extensions of ${CHECK_DATABASE} on ${CHECK_HOST}" >&2
		exit 1
	}
	CHECK_EXTENSIONS="${CHECK_EXTENSIONS} ${CHECK_DATABASE_EXTENSIONS}"
done
for EXTENSION in $(echo ${CHECK_EXTENSIONS} | tr ' ' '\n' | sort -u)
do
	if [ ! -f "$(${NEW_BINDIR}/pg_config --sharedir)/extension/${EXTENSION}.control" ]
	then
		echo "  ${EXTENSION}: NOT in this image"
		HAS_MISSING_EXTENSION=true
	fi
done
if [ -n "${HAS_MISSING_EXTENSION}" ]
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
su postgres -c "${NEW_BINDIR}/initdb -D ${CHECK_DIR}/new -E UTF8 ${NEW_CHECKSUM_ARG}" > /dev/null
# The files pg_upgrade points at on a failure ("a list of the problem columns is in the file")
# are written under the working directory the trap removes, so they are printed here or the
# operator is left with a pointer to a file that is already gone — on the one run where the
# detail is the whole point of running this.
if ! su postgres -c "cd ${CHECK_DIR} && ${NEW_BINDIR}/pg_upgrade --check --old-bindir=${OLD_BINDIR} --new-bindir=${NEW_BINDIR} --old-datadir=${CHECK_DIR}/old --new-datadir=${CHECK_DIR}/new"
then
	find ${CHECK_DIR} ${CHECK_DIR}/new/pg_upgrade_output.d -type f -name '*.txt' 2> /dev/null | while read REPORT_FILE
	do
		echo "--- $(basename ${REPORT_FILE})"
		cat ${REPORT_FILE}
	done
	exit 1
fi
