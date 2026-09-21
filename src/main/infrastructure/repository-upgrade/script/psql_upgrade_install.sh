#!/bin/sh

# Installs the server binaries of previous PostgreSQL versions, which psql_upgrade.sh needs
# to migrate data written by them. Run when this module is built, so that no version is ever
# downloaded while a database container is starting.
#
# The versions come from the first argument, or from PG_UPGRADE_FROM, which the Dockerfile of
# the version to migrate to declares. Nothing is installed when neither is set.

# Default script behavior.
set -o errexit

# Default parameters.
OLD_VERSIONS=${1:-${PG_UPGRADE_FROM:-}}
PGDG_LIST=/etc/apt/sources.list.d/pgdg.list
PGDG_UPGRADE_LIST=/etc/apt/sources.list.d/pgdg-upgrade.list

# Nothing to install: the image carries no binary it does not need.
if [ -z "${OLD_VERSIONS}" ]
then
	echo "PG_UPGRADE_FROM is empty: no previous PostgreSQL binaries installed"
	exit 0
fi

# Only the versions the data may come from make sense, and a build is the place to find that
# out: at this point the mistake costs a build, later it costs a database that will not start.
for OLD_VERSION in ${OLD_VERSIONS}
do
	case ${OLD_VERSION} in
		''|*[!0-9]*)
			echo "ERROR: PG_UPGRADE_FROM=${OLD_VERSIONS} is not a list of major versions" >&2
			exit 1
			;;
	esac
	if [ ${OLD_VERSION} -ge ${PG_MAJOR} ]
	then
		echo "ERROR: PG_UPGRADE_FROM=${OLD_VERSION} is not older than the PostgreSQL ${PG_MAJOR} of this image" >&2
		exit 1
	fi
done

# The repository configured in the image only carries the component of its own version, so
# the components of the versions to install are added in a list of their own.
if [ ! -f ${PGDG_LIST} ]
then
	echo "ERROR: ${PGDG_LIST} not found: this image does not install PostgreSQL from apt.postgresql.org" >&2
	exit 1
fi

echo "Installing the PostgreSQL ${OLD_VERSIONS} binaries for pg_upgrade"
sed -e "s/ main .*/ main ${OLD_VERSIONS}/" ${PGDG_LIST} > ${PGDG_UPGRADE_LIST}
apt-get update
for OLD_VERSION in ${OLD_VERSIONS}
do
	# The contrib modules come along: a cluster that preloads one of them, pg_stat_statements
	# being the usual case, does not start without the library, and pg_upgrade starts it.
	apt-get install -y --no-install-recommends postgresql-${OLD_VERSION} postgresql-contrib-${OLD_VERSION}

	# The extensions a deployment of that version may preload, which the old cluster does not
	# start without and which pg_upgrade starts it. pg_hint_plan is the one this project
	# installs, in its PostgreSQL 16 image; the package does not exist for every version, and
	# a version that never had it has nothing to load.
	if apt-cache show postgresql-${OLD_VERSION}-pg-hint-plan > /dev/null 2>&1
	then
		apt-get install -y --no-install-recommends postgresql-${OLD_VERSION}-pg-hint-plan
	else
		echo "No pg_hint_plan package for PostgreSQL ${OLD_VERSION}: a cluster of that version preloading it cannot be migrated by this image"
	fi
done
apt-get clean -y
rm -rf /var/lib/apt/lists/*
