#!/bin/sh

# Moves the data of a previous deployment into the data directory this image expects, when the
# two differ only by where they sit on the volume. PostgreSQL 18 keeps its data in a folder
# named after the major version (/var/lib/postgresql/18/docker) while earlier versions kept it
# at /var/lib/postgresql/data, so a volume that used to be mounted at the data directory itself
# and is now mounted at its parent holds the cluster at the volume root.
#
# Only data of this very major version is moved. That is a rename on the same filesystem: no
# byte is copied and no catalog is rewritten, which is why it belongs here and not in the
# repository-upgrade image. Data of an older version needs pg_upgrade and the binaries of that
# version, which only that image carries, so this reports it and stops rather than leaving the
# server to fail on data it cannot read.

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true
RELOCATE_ROOT=$(dirname ${PGDATA})

# Root of the mounted volume: the parent of the data directory, also skipping the version folder
# used by PostgreSQL 18 and later.
if [ "$(basename ${RELOCATE_ROOT})" = "${PG_MAJOR}" ]
then
	RELOCATE_ROOT=$(dirname ${RELOCATE_ROOT})
fi

# Enables interruption signal handling.
trap - INT TERM

# The data directory already holds a cluster, which is every start but the first after a mount
# point changes. Nothing is ever moved on top of existing data.
if [ -f "${PGDATA}/PG_VERSION" ]
then
	exit 0
fi

# Data left where a previous deployment kept it: at the volume root, at the legacy data folder,
# or under the folder of another major version.
RELOCATE_DATA=
for CANDIDATE in ${RELOCATE_ROOT} ${RELOCATE_ROOT}/data ${RELOCATE_ROOT}/*/docker ${RELOCATE_ROOT}/*/main
do
	if [ "${CANDIDATE}" != "${PGDATA}" ] && [ -f "${CANDIDATE}/PG_VERSION" ]
	then
		RELOCATE_DATA="${RELOCATE_DATA} ${CANDIDATE}"
	fi
done

# An empty volume, or data already where it is expected.
if [ -z "${RELOCATE_DATA}" ]
then
	exit 0
fi

# Which data is the one in use is never a guess.
if [ $(echo ${RELOCATE_DATA} | wc -w) -gt 1 ]
then
	echo "ERROR: more than one PostgreSQL data directory found under ${RELOCATE_ROOT} (${RELOCATE_DATA}) — keep only the one in use" >&2
	exit 1
fi
RELOCATE_DATA=$(echo ${RELOCATE_DATA})
RELOCATE_VERSION=$(cat ${RELOCATE_DATA}/PG_VERSION)

# Older data has to have its catalog rewritten, which needs the binaries of the version that
# wrote it. Reported here because the message the server would give is about a mount point.
if [ "${RELOCATE_VERSION}" != "${PG_MAJOR}" ]
then
	echo "ERROR: ${RELOCATE_DATA} holds PostgreSQL ${RELOCATE_VERSION} data and this image is PostgreSQL ${PG_MAJOR}." >&2
	echo "       Moving it is not enough: its catalog has to be migrated by pg_upgrade, which needs the" >&2
	echo "       PostgreSQL ${RELOCATE_VERSION} binaries. Deploy the repository-upgrade image once to migrate it," >&2
	echo "       then deploy this image again." >&2
	exit 1
fi

# Same major version, same filesystem: moving the entries is a rename, so an interrupted move
# leaves every entry in one place or the other and running again finishes it.
${DEBUG} && echo "Moving PostgreSQL ${RELOCATE_VERSION} data from ${RELOCATE_DATA} to ${PGDATA}"
mkdir -p ${PGDATA}
for ITEM in ${RELOCATE_DATA}/*
do
	case $(basename ${ITEM}) in
		lost+found|${PG_MAJOR})
			continue
			;;
	esac
	if [ -e "${ITEM}" ]
	then
		mv ${ITEM} ${PGDATA}/
	fi
done
chown -R postgres:postgres ${PGDATA}
chmod 700 ${PGDATA}
echo "PostgreSQL ${RELOCATE_VERSION} data moved to ${PGDATA}"
