#!/bin/sh

# Migrates the data of a previous deployment to the data directory expected by the
# PostgreSQL binaries of this image. Does nothing when there is nothing to migrate, so it
# is safe to run on every container start.
#
# Same major version (data written at another path): the data files are moved.
# Older major version: pg_upgrade is run with the server binaries of the old version, which
# are installed when the image is built (see psql_upgrade_install.sh).
#
# Parameters, all optional:
#   UPGRADE_ENABLED         false leaves any old data alone.
#   UPGRADE_MODE            auto (default), copy or link.
#   UPGRADE_ANALYZE         false skips rebuilding the planner statistics.
#   UPGRADE_KEEP_OLD_DATA   true keeps the old data on the volume after the upgrade.
#   UPGRADE_FORCE_RETRY     true retries an upgrade interrupted while hard linking.
#   UPGRADE_MOUNT_ROOT      root of the volume, when it is not the parent of PGDATA.
#   PG_UPGRADE_FROM         versions the image was built to migrate from, only used to
#                           report a divergence: what is migrated is what the volume holds.
#
# Control files, kept on the volume:
#   .pg_upgrade_state       phase of the migration and the version it migrates to, so a
#                           finished migration is never run again for that version, and an
#                           interrupted one is resumed on the next container start.
#   .pg_upgrade_history     one line for each migration that finished.

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true
UPGRADE_ENABLED=${UPGRADE_ENABLED:-true}
UPGRADE_MODE=${UPGRADE_MODE:-auto}
UPGRADE_ANALYZE=${UPGRADE_ANALYZE:-true}
UPGRADE_KEEP_OLD_DATA=${UPGRADE_KEEP_OLD_DATA:-false}
UPGRADE_FORCE_RETRY=${UPGRADE_FORCE_RETRY:-false}
UPGRADE_LOG_DIR=/tmp/pg_upgrade
NEW_VERSION=${PG_MAJOR}
NEW_BINDIR=/usr/lib/postgresql/${NEW_VERSION}/bin

# Root of the mounted volume: the parent of the data directory, also skipping the version
# folder used by PostgreSQL 18 and later (/var/lib/postgresql/18/docker).
MOUNT_ROOT=$(dirname ${PGDATA})
if [ "$(basename ${MOUNT_ROOT})" = "${NEW_VERSION}" ]
then
	MOUNT_ROOT=$(dirname ${MOUNT_ROOT})
fi
MOUNT_ROOT=${UPGRADE_MOUNT_ROOT:-${MOUNT_ROOT}}

# Migration phase, kept on the volume so an interrupted migration can be resumed.
STATE_FILE=${MOUNT_ROOT}/.pg_upgrade_state

# Enables interruption signal handling.
trap - INT TERM

# Aborts the container start with a message: better than starting PostgreSQL on the wrong
# (or on an empty) data directory.
upgrade_fail() {
	echo "PostgreSQL migration failed: ${1}" >&2
	exit 1
}

# Saves the migration phase, along with the data it applies to.
upgrade_save_state() {
	PHASE=${1}
	echo "${PHASE} ${OLD_VERSION} ${OLD_PGDATA} ${NEW_VERSION}" > ${STATE_FILE}
}

# Mount a path belongs to: the longest mount point it starts with. Device numbers cannot be
# used for this, since volumes of the same host usually share a filesystem and report the same
# device. Paths that do not exist yet are looked up on their closest existing ancestor.
upgrade_mount_point() {
	MOUNT_POINT_PATH=${1}
	while [ ! -d "${MOUNT_POINT_PATH}" ] && [ "${MOUNT_POINT_PATH}" != "/" ]
	do
		MOUNT_POINT_PATH=$(dirname ${MOUNT_POINT_PATH})
	done
	awk -v path="${MOUNT_POINT_PATH}/" '
		{ CURRENT = ($5 == "/" ? "/" : $5 "/") }
		index(path, CURRENT) == 1 && length(CURRENT) >= length(LONGEST) { LONGEST = CURRENT }
		END { if (LONGEST != "/") sub(/\/$/, "", LONGEST); print LONGEST }
	' /proc/self/mountinfo
}

# Lists the PostgreSQL versions whose server binaries are in the image, which is what tells
# the migrations it can actually run.
upgrade_installed_versions() {
	for BINDIR in /usr/lib/postgresql/*/bin
	do
		if [ -x "${BINDIR}/pg_ctl" ]
		then
			basename $(dirname ${BINDIR})
		fi
	done | tr '\n' ' ' | sed -e 's/ $//'
}

# Finds data written by a previous deployment: at the volume root (the volume used to be
# mounted at the data directory itself), at the legacy data folder, under the folder of
# another major version, or already staged by an interrupted migration.
upgrade_find_old_data() {
	for CANDIDATE in ${MOUNT_ROOT} ${MOUNT_ROOT}/data ${MOUNT_ROOT}/*/docker ${MOUNT_ROOT}/*/main ${MOUNT_ROOT}/.pg_upgrade_old_*
	do
		if [ "${CANDIDATE}" != "${PGDATA}" ] && [ -f "${CANDIDATE}/PG_VERSION" ]
		then
			echo ${CANDIDATE}
		fi
	done
}

# Reads the state of a previous migration attempt, if any. State of a migration to another
# version is ignored, so the next major upgrade starts from scratch.
PHASE=
OLD_VERSION=
OLD_PGDATA=
STATE_VERSION=
if [ -f "${STATE_FILE}" ]
then
	read PHASE OLD_VERSION OLD_PGDATA STATE_VERSION < ${STATE_FILE}
	if [ "${STATE_VERSION}" != "${NEW_VERSION}" ]
	then
		PHASE=
	fi
fi

# If migration is disabled, or has already been done on this volume, hands off right away.
if [ "${UPGRADE_ENABLED}" != "true" ] || [ "${PHASE}" = "done" ]
then
	exit 0
fi

# The data directory has to be inside the volume, never the volume root itself: the old
# data is staged next to it, and the volume root may hold entries of its own (lost+found).
if [ "${PGDATA}" = "${MOUNT_ROOT}" ]
then
	upgrade_fail "PGDATA (${PGDATA}) is the volume root — mount the volume at its parent folder instead."
fi

# A previous attempt was interrupted while pg_upgrade was hard linking data files: both
# clusters share data blocks at that point, so running it again can destroy the two of
# them. Needs an operator: restore the volume snapshot, or force the retry.
if [ "${PHASE}" = "linking" ] && [ "${UPGRADE_FORCE_RETRY}" != "true" ]
then
	upgrade_fail "an upgrade from ${OLD_VERSION} to ${NEW_VERSION} was interrupted while hard linking data files, so ${OLD_PGDATA} and ${PGDATA} share data blocks. Restore the volume from a snapshot, or set UPGRADE_FORCE_RETRY=true to upgrade the old data again."
fi

# Resumes the interrupted migration, or looks for data left by a previous deployment.
if [ -n "${PHASE}" ] && [ -d "${OLD_PGDATA}" ]
then
	echo "Resuming PostgreSQL ${OLD_VERSION} migration interrupted at phase ${PHASE}"
else

	OLD_DATA=$(upgrade_find_old_data)

	# Nothing to migrate: an empty volume, or data already at the expected path.
	if [ -z "${OLD_DATA}" ]
	then
		exit 0
	fi

	# Which data is the one in use is never a guess.
	if [ $(echo "${OLD_DATA}" | wc -l) -gt 1 ]
	then
		upgrade_fail "more than one PostgreSQL data directory found under ${MOUNT_ROOT} ($(echo ${OLD_DATA})) — keep only the one to migrate."
	fi
	if [ -f "${PGDATA}/PG_VERSION" ]
	then
		upgrade_fail "data found both at ${PGDATA} and at ${OLD_DATA} — remove the one that is not in use."
	fi

	OLD_PGDATA=${OLD_DATA}
	OLD_VERSION=$(cat ${OLD_PGDATA}/PG_VERSION)

fi

# Newer data cannot be read by older binaries, and starting anyway would initialize an
# empty cluster next to data that is still there.
if [ ${OLD_VERSION%%.*} -gt ${NEW_VERSION} ]
then
	upgrade_fail "the volume holds PostgreSQL ${OLD_VERSION} data and this image ships ${NEW_VERSION} — deploy the image of version ${OLD_VERSION} or newer."
fi

echo "Migrating PostgreSQL ${OLD_VERSION} data at ${OLD_PGDATA} to ${NEW_VERSION} at ${PGDATA}"

# The version this image was built to migrate from is only a declaration: what gets migrated
# is the data the volume actually holds, so a divergence is reported and not obeyed.
if [ -n "${PG_UPGRADE_FROM:-}" ]
then
	case " ${PG_UPGRADE_FROM} " in
		*" ${OLD_VERSION} "*)
			;;
		*)
			echo "This image declares PG_UPGRADE_FROM=${PG_UPGRADE_FROM}, and the volume holds PostgreSQL ${OLD_VERSION} data"
			;;
	esac
fi

# The old and the new data directories have to be on the same mount: that is what makes moving
# the files a rename instead of a copy, and what lets pg_upgrade hard link them. It also
# catches the volume mounted at the wrong path, which is easy to run into because PostgreSQL
# 18 keeps its data at ${MOUNT_ROOT}/${NEW_VERSION}/docker while earlier versions kept it at
# ${MOUNT_ROOT}/data: a job still mounting the volume at the old path would have the new data
# directory land outside the volume, and lose it when the container is replaced.
OLD_MOUNT=$(upgrade_mount_point ${OLD_PGDATA})
NEW_MOUNT=$(upgrade_mount_point ${PGDATA})
if [ "${OLD_MOUNT}" != "${NEW_MOUNT}" ]
then
	upgrade_fail "${OLD_PGDATA} and ${PGDATA} are on different mounts (${OLD_MOUNT} and ${NEW_MOUNT}), so the migrated data would not land on the volume — mount the volume at ${MOUNT_ROOT}, which is where PostgreSQL ${NEW_VERSION} keeps its data."
fi

# The server binaries of the old version are needed to read its catalog, and are installed
# when the image is built: nothing is downloaded while a database is starting. Checked before
# any data is touched, so an image that cannot migrate leaves the volume as it found it.
OLD_BINDIR=/usr/lib/postgresql/${OLD_VERSION}/bin
if [ "${OLD_VERSION}" != "${NEW_VERSION}" ] && [ ! -x "${OLD_BINDIR}/pg_ctl" ]
then
	upgrade_fail "the PostgreSQL ${OLD_VERSION} binaries are not in this image, which carries the binaries of: $(upgrade_installed_versions). Add ${OLD_VERSION} to PG_UPGRADE_FROM in the Dockerfile of the repository-upgrade module, and deploy the image it builds."
fi

# Stages the old data in a folder of its own, so the volume root only holds version folders
# and the migration can be resumed, retried or rolled back from a known path. Both paths
# are on the same volume, so moving is a rename: no data is copied. Data already staged is
# left alone, which is what makes an interrupted staging safe to run again.
OLD_STAGED_DATA=${MOUNT_ROOT}/.pg_upgrade_old_${OLD_VERSION}
if [ "${OLD_PGDATA}" != "${OLD_STAGED_DATA}" ]
then
	${DEBUG} && echo "Staging PostgreSQL ${OLD_VERSION} data at ${OLD_STAGED_DATA}"
	upgrade_save_state staging
	if [ "${OLD_PGDATA}" = "${MOUNT_ROOT}" ]
	then
		mkdir -p ${OLD_STAGED_DATA}
		for ITEM in ${MOUNT_ROOT}/*
		do
			case $(basename ${ITEM}) in
				lost+found|${NEW_VERSION})
					continue
					;;
			esac
			mv ${ITEM} ${OLD_STAGED_DATA}/
		done
	else
		mv ${OLD_PGDATA} ${OLD_STAGED_DATA}
	fi
	OLD_PGDATA=${OLD_STAGED_DATA}
	upgrade_save_state staged
fi

# PostgreSQL refuses to start on a data directory it does not own, or that others can read:
# the volume root is usually mounted world writable.
chown -R postgres:postgres ${OLD_PGDATA}
chmod 700 ${OLD_PGDATA}

# Same major version: the on-disk format is compatible, so moving the data files is enough.
if [ "${OLD_VERSION}" = "${NEW_VERSION}" ]
then

	if [ "${PHASE}" != "migrated" ]
	then
		echo "Moving PostgreSQL ${OLD_VERSION} data files to ${PGDATA}"
		upgrade_save_state moving
		mkdir -p ${PGDATA}
		for ITEM in ${OLD_PGDATA}/*
		do
			if [ -e "${ITEM}" ]
			then
				mv ${ITEM} ${PGDATA}/
			fi
		done
		chown -R postgres:postgres ${PGDATA}
		chmod 700 ${PGDATA}
		upgrade_save_state migrated
	fi

# Older major version: the catalog has to be rewritten by pg_upgrade.
else

	if [ "${PHASE}" != "migrated" ]
	then

		# pg_upgrade aborts when the old cluster was not shut down cleanly, and when it finds
		# a process identifier file (even of a process that is long gone, which is always the
		# case in a container that has just started). Starting and stopping the old cluster
		# completes the pending crash recovery. Local connections are trusted while it runs,
		# since pg_upgrade connects to it without a password.
		rm -f ${OLD_PGDATA}/postmaster.pid
		if [ ! -f ${OLD_PGDATA}/pg_hba.conf.preupgrade ]
		then
			cp ${OLD_PGDATA}/pg_hba.conf ${OLD_PGDATA}/pg_hba.conf.preupgrade
		fi
		echo "local all all trust" > ${OLD_PGDATA}/pg_hba.conf
		echo "Starting PostgreSQL ${OLD_VERSION} to complete crash recovery"
		su postgres -c "${OLD_BINDIR}/pg_ctl start -D ${OLD_PGDATA} -w -t 3600 -o '-c listen_addresses= -c unix_socket_directories=/tmp'"

		# Reads the locale and the encoding of the old cluster, which the new one has to
		# match: pg_upgrade compares them database by database and refuses to go on when they
		# differ. The locale provider column only exists from PostgreSQL 15 on.
		OLD_LOCALE_PROVIDER=$(su postgres -c "psql -h /tmp -d template1 -At -c \"SELECT datlocprovider FROM pg_database WHERE datname = 'template0';\"" 2> /dev/null || echo c)
		OLD_ENCODING=$(su postgres -c "psql -h /tmp -d template1 -At -c \"SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = 'template0';\"")
		OLD_COLLATE=$(su postgres -c "psql -h /tmp -d template1 -At -c \"SELECT datcollate FROM pg_database WHERE datname = 'template0';\"")
		OLD_CTYPE=$(su postgres -c "psql -h /tmp -d template1 -At -c \"SELECT datctype FROM pg_database WHERE datname = 'template0';\"")
		su postgres -c "${OLD_BINDIR}/pg_ctl stop -D ${OLD_PGDATA} -m fast -w"

		# Reproducing a provider other than libc would need options initdb only accepts in
		# some versions, and no coldis image uses one.
		if [ -n "${OLD_LOCALE_PROVIDER}" ] && [ "${OLD_LOCALE_PROVIDER}" != "c" ]
		then
			upgrade_fail "the PostgreSQL ${OLD_VERSION} cluster uses the ${OLD_LOCALE_PROVIDER} locale provider, which is not handled here — upgrade it by hand with pg_upgrade."
		fi

		# Matches the data checksum setting of the old cluster, which pg_upgrade also requires
		# to be the same on both. PostgreSQL 18 initializes clusters with checksums, earlier
		# versions without them (and their initdb has no option to turn them off). Read under
		# the C locale, since pg_controldata translates its labels and this image runs in
		# pt_BR: a label that does not match would leave the setting unread.
		OLD_CHECKSUMS=$(LC_ALL=C ${OLD_BINDIR}/pg_controldata ${OLD_PGDATA} | sed -n 's/^Data page checksum version: *//p')
		case "${OLD_CHECKSUMS}" in
			''|*[!0-9]*)
				upgrade_fail "the data page checksum setting of the PostgreSQL ${OLD_VERSION} cluster could not be read from its control data — initializing the new cluster with the wrong setting would only fail later, in pg_upgrade."
				;;
		esac
		if [ "${OLD_CHECKSUMS}" != "0" ]
		then
			CHECKSUM_ARG=--data-checksums
		elif ${NEW_BINDIR}/initdb --help | grep -q -- --no-data-checksums
		then
			CHECKSUM_ARG=--no-data-checksums
		else
			CHECKSUM_ARG=
		fi

		# Initializes the new cluster: pg_upgrade migrates the old catalog into it. Anything
		# left by an interrupted attempt is discarded, since initdb needs an empty folder.
		echo "Initializing PostgreSQL ${NEW_VERSION} at ${PGDATA} (${OLD_ENCODING}, ${OLD_COLLATE})"
		upgrade_save_state initializing
		rm -rf ${PGDATA}
		mkdir -p ${PGDATA}
		chown postgres:postgres ${PGDATA}
		chmod 700 ${PGDATA}
		su postgres -c "${NEW_BINDIR}/initdb -D ${PGDATA} ${CHECKSUM_ARG} --encoding=${OLD_ENCODING} --lc-collate=${OLD_COLLATE} --lc-ctype=${OLD_CTYPE}"

		# Copies the data files when the volume has room for a second copy of them: the old
		# cluster stays intact, so an interrupted upgrade is retried on the next start with
		# nothing lost. Falls back to hard links, which need almost no extra space but leave
		# both clusters sharing data blocks, and the old one unusable.
		MODE=${UPGRADE_MODE}
		if [ "${MODE}" = "auto" ]
		then
			OLD_DATA_SIZE=$(du -sk ${OLD_PGDATA} | cut -f1)
			FREE_SIZE=$(df -Pk ${MOUNT_ROOT} | awk 'NR == 2 { print $4 }')
			if [ ${FREE_SIZE} -gt $(( OLD_DATA_SIZE * 12 / 10 )) ]
			then
				MODE=copy
			else
				MODE=link
			fi
		fi

		# Upgrades the catalog. pg_upgrade writes its logs and its scripts in the current
		# folder, which has to be writable by the postgres user.
		echo "Running pg_upgrade from ${OLD_VERSION} to ${NEW_VERSION} in ${MODE} mode"
		if [ "${MODE}" = "link" ]
		then
			upgrade_save_state linking
		else
			upgrade_save_state copying
		fi
		rm -rf ${UPGRADE_LOG_DIR}
		mkdir -p ${UPGRADE_LOG_DIR}
		chown postgres:postgres ${UPGRADE_LOG_DIR}
		if ! su postgres -c "cd ${UPGRADE_LOG_DIR} && ${NEW_BINDIR}/pg_upgrade --old-bindir=${OLD_BINDIR} --new-bindir=${NEW_BINDIR} --old-datadir=${OLD_PGDATA} --new-datadir=${PGDATA} --${MODE}"
		then
			find ${UPGRADE_LOG_DIR} -type f \( -name '*.log' -o -name '*.txt' \) | while read LOG_FILE
			do
				echo "--- ${LOG_FILE}"
				tail -n 50 ${LOG_FILE}
			done
			upgrade_fail "pg_upgrade from ${OLD_VERSION} to ${NEW_VERSION} did not finish (see the logs above)."
		fi
		upgrade_save_state migrated

	fi

fi

# Finishes the migration with the cluster running on a private socket only: no TCP, so the
# health check of the container cannot take this transient start for a healthy database and
# send traffic before psql_init.sh takes over.
echo "Finishing PostgreSQL ${NEW_VERSION} migration"
ADMIN_USER=${POSTGRES_ADMIN_USER:=postgres}
ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD:=postgres}
TEMP_HBA=$(mktemp /tmp/pg_hba_XXXXXX.conf)
echo "local all all trust" > ${TEMP_HBA}
chmod 644 ${TEMP_HBA}
su postgres -c "${NEW_BINDIR}/pg_ctl start -D ${PGDATA} -w -t 3600 -o '-c hba_file=${TEMP_HBA} -c listen_addresses= -c unix_socket_directories=/tmp'"

# Sets the admin password when the migrated cluster has none: the old deployment may have
# trusted its local connections, while the configuration psql_init.sh writes asks for a
# password, and psql_configure.sh would wait for a connection it can never make.
HAS_PASSWORD=$(su postgres -c "psql -h /tmp -d postgres -At -c \"SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = '${ADMIN_USER}';\"")
if [ "${HAS_PASSWORD}" = "f" ]
then
	echo "Setting the password of ${ADMIN_USER}"
	su postgres -c "PGOPTIONS='-c log_statement=none' psql -h /tmp -d postgres -c \"ALTER USER ${ADMIN_USER} PASSWORD '${ADMIN_PASSWORD}';\""
fi

# Updates the extensions pg_upgrade kept at the version of the old binaries.
if [ -f ${UPGRADE_LOG_DIR}/update_extensions.sql ]
then
	echo "Updating extensions"
	su postgres -c "psql -h /tmp -d postgres -f ${UPGRADE_LOG_DIR}/update_extensions.sql"
fi

su postgres -c "${NEW_BINDIR}/pg_ctl stop -D ${PGDATA} -m fast -w"
rm -f ${TEMP_HBA}

# Drops the old data. In link mode its files are already shared with the new cluster, so
# only directory entries go away; in copy mode this is the copy to roll back to, so keep it
# with UPGRADE_KEEP_OLD_DATA=true when the space it takes is not a problem.
if [ "${UPGRADE_KEEP_OLD_DATA}" = "true" ]
then
	echo "Keeping the old PostgreSQL ${OLD_VERSION} data at ${OLD_PGDATA}"
	if [ "${MODE:-${UPGRADE_MODE}}" != "copy" ]
	then
		echo "The old data shares its data files with ${PGDATA}: starting it would corrupt both"
	fi
	if [ -f ${OLD_PGDATA}/pg_hba.conf.preupgrade ]
	then
		mv ${OLD_PGDATA}/pg_hba.conf.preupgrade ${OLD_PGDATA}/pg_hba.conf
	fi
else
	echo "Removing the old PostgreSQL ${OLD_VERSION} data at ${OLD_PGDATA}"
	rm -rf ${OLD_PGDATA}
fi
# Records the migration on the volume: the state file keeps it from running again, and the
# history keeps the trail of what this volume went through.
upgrade_save_state done
echo "$(date -Is) PostgreSQL ${OLD_VERSION} migrated to ${NEW_VERSION} (${MODE:-move})" >> ${MOUNT_ROOT}/.pg_upgrade_history
echo "PostgreSQL ${OLD_VERSION} data migrated to ${NEW_VERSION}"

# Rebuilds the planner statistics in the background: pg_upgrade does not carry them over,
# and rebuilding them here would hold the server startup for as long as it takes on a large
# database. Waits for the server psql_init.sh is about to start, as psql_configure.sh does.
if [ "${UPGRADE_ANALYZE}" = "true" ] && [ "${OLD_VERSION}" != "${NEW_VERSION}" ]
then
	(
		while !(PGPASSWORD=${ADMIN_PASSWORD} psql -U ${ADMIN_USER} -d postgres -c 'SELECT 1;' > /dev/null 2>&1)
		do
			sleep 1
		done
		echo "Rebuilding the planner statistics after the upgrade"
		PGPASSWORD=${ADMIN_PASSWORD} vacuumdb --all --analyze-in-stages -U ${ADMIN_USER} > /dev/null
		echo "Planner statistics rebuilt"
	) &
fi
