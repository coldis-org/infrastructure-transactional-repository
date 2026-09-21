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
NEW_VERSION=${PG_MAJOR}
NEW_BINDIR=/usr/lib/postgresql/${NEW_VERSION}/bin
# The transient clusters are reached over a socket of their own rather than one in /tmp, which
# any process in the container can write to, and on a port of their own rather than the one the
# deployment configures: everything here connects to this pair. Created when the first cluster
# is about to start, so a container that has nothing to migrate leaves nothing behind.
UPGRADE_SOCKET_DIR=
UPGRADE_PORT=5499

# The superuser of the deployment, which the repository image allows renaming: pg_upgrade and
# every connection made here have to name it, since a migrated cluster has no role named after
# the operating system user unless the deployment happens to call it that. It reaches a shell
# started by su and an SQL literal, so it is checked once here rather than quoted at each use.
ADMIN_USER=${POSTGRES_ADMIN_USER:=postgres}
ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD:-}
case "${ADMIN_USER}" in
	''|*[!A-Za-z0-9_]*)
		echo "PostgreSQL migration failed: POSTGRES_ADMIN_USER (${ADMIN_USER}) is not a plain identifier" >&2
		exit 1
		;;
esac

# Root of the mounted volume: the parent of the data directory, also skipping the version
# folder used by PostgreSQL 18 and later (/var/lib/postgresql/18/docker).
MOUNT_ROOT=$(dirname ${PGDATA})
if [ "$(basename ${MOUNT_ROOT})" = "${NEW_VERSION}" ]
then
	MOUNT_ROOT=$(dirname ${MOUNT_ROOT})
fi
MOUNT_ROOT=${UPGRADE_MOUNT_ROOT:-${MOUNT_ROOT}}

# Migration phase, kept on the volume so an interrupted migration can be resumed. The working
# folder of pg_upgrade goes there too: it holds update_extensions.sql, which a run resumed in a
# new container still has to apply.
STATE_FILE=${MOUNT_ROOT}/.pg_upgrade_state
UPGRADE_LOG_DIR=${MOUNT_ROOT}/.pg_upgrade_work

# Enables interruption signal handling.
trap - INT TERM

# Puts back what the migration borrowed: the staged cluster's own authentication rules, which
# are replaced by a trust rule while pg_upgrade needs to reach it, and the socket directory.
# Armed only once those exist, so nothing here can act on a value that has not been checked.
# INT and TERM are caught along with EXIT, since a shell killed by a signal it does not handle
# never reaches its EXIT trap. They cover a signal sent to this script and not a container stop:
# the entrypoint is process 1 and resets both to their default action, so a stop kills it and
# the kernel then kills this one with a signal nothing can catch. What covers the container stop
# is the recovery this script performs when it starts — the file a previous container left
# replaced is put back below, and the socket directory lives in an ephemeral /tmp.
upgrade_clean_up() {
	if [ -n "${OLD_PGDATA}" ] && [ -f "${OLD_PGDATA}/pg_hba.conf.preupgrade" ]
	then
		mv "${OLD_PGDATA}/pg_hba.conf.preupgrade" "${OLD_PGDATA}/pg_hba.conf"
	fi
	if [ -n "${UPGRADE_SOCKET_DIR}" ]
	then
		rm -rf "${UPGRADE_SOCKET_DIR}"
	fi
}

# Aborts the container start with a message: better than starting PostgreSQL on the wrong
# (or on an empty) data directory.
upgrade_fail() {
	echo "PostgreSQL migration failed: ${1}" >&2
	exit 1
}

# Saves the migration phase, along with the data and the mode it applies to. The phase read
# from the volume is left alone: it is what the resume guards below decide on, and it has to
# keep meaning "where a previous run stopped" for the whole life of this one.
upgrade_save_state() {
	SAVED_PHASE=${1}
	echo "${SAVED_PHASE} ${OLD_VERSION} ${OLD_PGDATA} ${NEW_VERSION} ${RESOLVED_MODE}" > ${STATE_FILE}
}

# Mount a path belongs to. Device numbers cannot be used for this, since volumes of the same
# host usually share a filesystem and report the same device. Paths that do not exist yet are
# looked up on their closest existing ancestor, which is what df needs.
upgrade_mount_point() {
	MOUNT_POINT_PATH=${1}
	while [ ! -d "${MOUNT_POINT_PATH}" ] && [ "${MOUNT_POINT_PATH}" != "/" ]
	do
		MOUNT_POINT_PATH=$(dirname ${MOUNT_POINT_PATH})
	done
	df --output=target ${MOUNT_POINT_PATH} | tail -1
}

# Reports whether a server configuration is one the given binaries can start on, and stops the
# migration when it is not. Nothing is rewritten: a migration that quietly changes what a
# deployment runs with is worse than one that refuses and says why, and refusing costs only a
# deployment while the volume is still untouched.
upgrade_check_conf() {
	CHECK_BINDIR=${1}
	CHECK_CONF=${2}
	CHECK_REJECTED=

	# An empty bindir is a caller reading a variable before it is set, and an unquoted empty
	# word disappears from the argument list rather than arriving empty: that turned this whole
	# function into a silent success once already, so it is an error and not "nothing to check".
	if [ ! -x "${CHECK_BINDIR}/postgres" ]
	then
		upgrade_fail "upgrade_check_conf was given '${CHECK_BINDIR}' as the binaries to check against, which is not a PostgreSQL installation."
	fi
	if [ ! -f "${CHECK_CONF}" ]
	then
		return 0
	fi

	# The parameters these binaries know, folded to lower case: the binary reports the canonical
	# spelling of a name (DateStyle) while a configuration may use any other.
	CHECK_KNOWN=$(
		{
			${CHECK_BINDIR}/postgres --describe-config | cut -f1
			echo include
			echo include_if_exists
			echo include_dir
		} | tr 'A-Z' 'a-z'
	)
	CHECK_LIBDIR=$(${CHECK_BINDIR}/pg_config --pkglibdir)

	while IFS= read -r CHECK_LINE
	do
		CHECK_NAME=$(echo "${CHECK_LINE}" | sed -e 's/#.*//' -e 's/=.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]].*//' | tr 'A-Z' 'a-z')
		case "${CHECK_NAME}" in
			# A qualified name belongs to an extension, and the server accepts it as a placeholder
			# whether or not the library is loaded.
			''|*.*)
				continue
				;;
			include|include_if_exists|include_dir)
				echo "  ${CHECK_CONF}: ${CHECK_NAME} is not followed into, so what it pulls in is not checked" >&2
				continue
				;;
			shared_preload_libraries)
				CHECK_VALUE=$(echo "${CHECK_LINE}" | sed -e 's/^[^=]*=//' -e 's/#.*//' | tr -d " \t'\"" | tr ',' ' ')
				for CHECK_LIBRARY in ${CHECK_VALUE}
				do
					if [ ! -f "${CHECK_LIBDIR}/${CHECK_LIBRARY#\$libdir/}.so" ]
					then
						echo "  ${CHECK_CONF}: preloads ${CHECK_LIBRARY}, which is not installed in this image" >&2
						CHECK_REJECTED=true
					fi
				done
				continue
				;;
		esac
		if ! echo "${CHECK_KNOWN}" | grep -qx "${CHECK_NAME}"
		then
			echo "  ${CHECK_CONF}: sets ${CHECK_NAME}, which these binaries do not have" >&2
			CHECK_REJECTED=true
		fi
	done < ${CHECK_CONF}

	if [ -n "${CHECK_REJECTED}" ]
	then
		upgrade_fail "${CHECK_CONF} would keep the server from starting — correct it in the deployment and migrate again. Nothing on the volume has been touched."
	fi
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
# another major version.
#
# Data already staged by a migration counts only when there is none of the above, and never
# alongside it: UPGRADE_KEEP_OLD_DATA leaves a staged folder behind on purpose, and a volume
# that holds one is a volume the next migration has to read, not one it should refuse as
# ambiguous.
upgrade_find_old_data() {
	FOUND_LIVE_DATA=
	for CANDIDATE in ${MOUNT_ROOT} ${MOUNT_ROOT}/data ${MOUNT_ROOT}/*/docker ${MOUNT_ROOT}/*/main
	do
		if [ "${CANDIDATE}" != "${PGDATA}" ] && [ -f "${CANDIDATE}/PG_VERSION" ]
		then
			echo ${CANDIDATE}
			FOUND_LIVE_DATA=true
		fi
	done
	if [ -z "${FOUND_LIVE_DATA}" ]
	then
		for CANDIDATE in ${MOUNT_ROOT}/.pg_upgrade_old_*
		do
			if [ -f "${CANDIDATE}/PG_VERSION" ]
			then
				echo ${CANDIDATE}
			fi
		done
	fi
}

# Reads the state of a previous migration attempt, if any. State of a migration to another
# version is ignored, so the next major upgrade starts from scratch.
PHASE=
OLD_VERSION=
OLD_PGDATA=
STATE_VERSION=
STATE_MODE=
if [ -f "${STATE_FILE}" ]
then
	# An empty file is what upgrade_save_state leaves behind when a container dies between the
	# truncation and the write, which is exactly when the resume logic is supposed to help.
	read PHASE OLD_VERSION OLD_PGDATA STATE_VERSION STATE_MODE < ${STATE_FILE} || PHASE=
	if [ "${STATE_VERSION}" != "${NEW_VERSION}" ]
	then
		PHASE=
		OLD_VERSION=
		OLD_PGDATA=
		STATE_MODE=
	fi
fi

# If migration is disabled, or has already been done on this volume, hands off right away. This
# comes before every check below: a deployment that turned the migration off, or one that has
# already migrated, has to be able to start whatever the volume or the environment say.
if [ "${UPGRADE_ENABLED}" != "true" ] || [ "${PHASE}" = "done" ]
then
	exit 0
fi

# What comes back off the volume is checked before it is used, the same way the environment is.
# These fields reach rm -rf, chown and mv running as root, and the command string of a su, so a
# volume whose root anyone can write to would otherwise hand those to whoever wrote the file.
# Checked here rather than quoted at each use, so a use added later is safe by default.
if [ -n "${PHASE}" ]
then
	case "${PHASE}" in
		staging|staged|moving|initializing|copying|linking|migrated|done)
			;;
		*)
			upgrade_fail "${STATE_FILE} records '${PHASE}', which is not a phase this writes."
			;;
	esac
	case "${OLD_VERSION}" in
		''|*[!0-9]*)
			upgrade_fail "${STATE_FILE} records '${OLD_VERSION}' as the version migrated from, which is not a major version."
			;;
	esac
	case "${STATE_MODE}" in
		''|auto|copy|link|move)
			;;
		*)
			upgrade_fail "${STATE_FILE} records '${STATE_MODE}' as the mode it was migrating in, which is not a mode this writes."
			;;
	esac
	case "${OLD_PGDATA}" in
		${MOUNT_ROOT}/*[!A-Za-z0-9_./-]*|*..*)
			upgrade_fail "${STATE_FILE} records '${OLD_PGDATA}' as the data it applies to, which is not a plain path."
			;;
		${MOUNT_ROOT}|${MOUNT_ROOT}/?*)
			;;
		*)
			upgrade_fail "${STATE_FILE} records '${OLD_PGDATA}' as the data it applies to, which is not inside ${MOUNT_ROOT}. Remove ${STATE_FILE} to start over from what the volume holds."
			;;
	esac
fi

# The mode a previous run resolved, so a run that resumes past the migration reports what was
# actually done rather than what was asked for. A state file written before this was recorded
# leaves it empty, and the request is the best guess left.
RESOLVED_MODE=${STATE_MODE:-${UPGRADE_MODE}}

# The configuration the migrated cluster will serve on is the one psql_init.sh installs from
# /tmp over it. It is checked before anything is read or moved, so a deployment whose
# configuration the new binaries cannot read fails with the volume untouched instead of after
# the point of no return — and after the switch above, so turning the migration off still
# starts the database and a volume already migrated is not held back by it.
upgrade_check_conf "${NEW_BINDIR}" /tmp/postgresql.conf

# Only these three are understood, and the value is typed by hand into a job during a window:
# anything else reaches pg_upgrade as an unknown option, after the new cluster has been built.
case "${UPGRADE_MODE}" in
	auto|copy|link)
		;;
	*)
		upgrade_fail "UPGRADE_MODE (${UPGRADE_MODE}) is not one of auto, copy or link."
		;;
esac

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

	# Read off the volume like the state file, and checked the same way: it builds the path to
	# the binaries that are run, and the name of the folder the data is staged in.
	case "${OLD_VERSION}" in
		''|*[!0-9.]*)
			upgrade_fail "${OLD_PGDATA}/PG_VERSION reads '${OLD_VERSION}', which is not a version."
			;;
	esac

fi

# Newer data cannot be read by older binaries, and starting anyway would initialize an
# empty cluster next to data that is still there.
if [ ${OLD_VERSION%%.*} -gt ${NEW_VERSION} ]
then
	upgrade_fail "the volume holds PostgreSQL ${OLD_VERSION} data and this image ships ${NEW_VERSION} — deploy the image of version ${OLD_VERSION} or newer."
fi

# The server binaries of the old version are needed to read its catalog, and are installed
# when the image is built: nothing is downloaded while a database is starting. Resolved here,
# before the checks that use it and before any data is touched, so an image that cannot migrate
# leaves the volume as it found it.
OLD_BINDIR=/usr/lib/postgresql/${OLD_VERSION}/bin
if [ "${OLD_VERSION}" != "${NEW_VERSION}" ]
then
	if [ ! -x "${OLD_BINDIR}/pg_ctl" ]
	then
		upgrade_fail "the PostgreSQL ${OLD_VERSION} binaries are not in this image, which carries the binaries of: $(upgrade_installed_versions). Add ${OLD_VERSION} to PG_UPGRADE_FROM in the Dockerfile of the repository-upgrade module, and deploy the image it builds."
	fi

fi

# The old cluster's own configuration has to be one these binaries can start on: across majors
# it is started here and by pg_upgrade, and on the same major it is moved into the data
# directory and started there. Both bindirs are the same on that path, so one call covers it.
upgrade_check_conf "${OLD_BINDIR}" "${OLD_PGDATA}/postgresql.conf"

# The deployment's admin password, which psql_configure.sh needs to reach the migrated cluster
# and which this writes into it when the old one had none. The repository image defaults it to
# the literal postgres, a placeholder everywhere else that would become a real superuser
# password on a cluster psql_init.sh goes on to expose with host all all 0.0.0.0/0 md5. Asked
# for only once there is something to migrate, and before pg_upgrade, which in link mode is
# past the point of return.
case "${ADMIN_PASSWORD}" in
	''|postgres)
		upgrade_fail "POSTGRES_ADMIN_PASSWORD is unset or still the default — set it to the password of the deployment before migrating."
		;;
esac

# A container killed by a signal it cannot catch leaves the trust rule on the staged cluster;
# the deployment's own file goes back before anything else reads it.
if [ -f "${OLD_PGDATA}/pg_hba.conf.preupgrade" ]
then
	echo "Restoring the authentication rules an interrupted migration left replaced"
	mv "${OLD_PGDATA}/pg_hba.conf.preupgrade" "${OLD_PGDATA}/pg_hba.conf"
fi

# From here the migration borrows a socket directory and the cluster's authentication rules,
# and the handlers that put them back are armed. Everything that can decline to migrate has
# already run, so nothing below exits without passing through them.
UPGRADE_SOCKET_DIR=$(mktemp -d /tmp/pg_socket_XXXXXX)
chown postgres:postgres "${UPGRADE_SOCKET_DIR}"
chmod 700 "${UPGRADE_SOCKET_DIR}"
trap upgrade_clean_up EXIT
trap 'upgrade_clean_up; exit 130' INT
trap 'upgrade_clean_up; exit 143' TERM

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

# Stages the old data in a folder of its own, so the volume root only holds version folders
# and the migration can be resumed, retried or rolled back from a known path. Both paths
# are on the same volume, so moving is a rename: no data is copied. Data already staged is
# left alone, which is what makes an interrupted staging safe to run again.
OLD_STAGED_DATA=${MOUNT_ROOT}/.pg_upgrade_old_${OLD_VERSION}
if [ "${OLD_PGDATA}" != "${OLD_STAGED_DATA}" ]
then
	# mv moves the source into a target directory that already exists, rather than over it: a
	# staged folder of the same version left behind by an earlier migration would end up holding
	# the data of the deployment as a subfolder, while everything below went on reading the stale
	# cluster — and the removal at the end took the live data with it, silently. The move is a
	# rename, so it either happened, and then the data is found already staged and this whole
	# block is skipped, or it did not: an existing target here is always a folder somebody left,
	# and the operator says what to do with it. The root layout below moves entries into a folder
	# it creates, which is what makes an interrupted staging safe to run again, so it is the one
	# case that legitimately writes into a directory that is already there.
	if [ "${OLD_PGDATA}" != "${MOUNT_ROOT}" ] && [ -e "${OLD_STAGED_DATA}" ]
	then
		upgrade_fail "${OLD_STAGED_DATA} is already there, and the data to migrate is at ${OLD_PGDATA} — remove or rename the folder a previous migration left behind. Nothing on the volume has been touched."
	fi
	${DEBUG} && echo "Staging PostgreSQL ${OLD_VERSION} data at ${OLD_STAGED_DATA}"
	upgrade_save_state staging
	if [ "${OLD_PGDATA}" = "${MOUNT_ROOT}" ]
	then
		mkdir -p ${OLD_STAGED_DATA}
		for DATA_ENTRY in ${MOUNT_ROOT}/*
		do
			case $(basename ${DATA_ENTRY}) in
				lost+found|${NEW_VERSION})
					continue
					;;
			esac
			mv ${DATA_ENTRY} ${OLD_STAGED_DATA}/
		done
	else
		mv "${OLD_PGDATA}" "${OLD_STAGED_DATA}"
	fi
	OLD_PGDATA=${OLD_STAGED_DATA}
	upgrade_save_state staged
fi

# PostgreSQL refuses to start on a data directory it does not own, or that others can read:
# the volume root may be mounted with looser permissions than a data directory accepts.
chown -R postgres:postgres "${OLD_PGDATA}"
chmod 700 "${OLD_PGDATA}"

# Same major version: the on-disk format is compatible, so moving the data files is enough.
if [ "${OLD_VERSION}" = "${NEW_VERSION}" ]
then

	if [ "${PHASE}" != "migrated" ]
	then
		RESOLVED_MODE=move
		echo "Moving PostgreSQL ${OLD_VERSION} data files to ${PGDATA}"
		upgrade_save_state moving
		mkdir -p "${PGDATA}"
		for DATA_ENTRY in ${OLD_PGDATA}/*
		do
			if [ -e "${DATA_ENTRY}" ]
			then
				mv ${DATA_ENTRY} ${PGDATA}/
			fi
		done
		chown -R postgres:postgres ${PGDATA}
		chmod 700 "${PGDATA}"
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
		su postgres -c "${OLD_BINDIR}/pg_ctl start -D ${OLD_PGDATA} -w -t 3600 -o '-c listen_addresses= -c port=${UPGRADE_PORT} -c unix_socket_directories=${UPGRADE_SOCKET_DIR}'"

		# Reads the locale and the encoding of the old cluster, which the new one has to
		# match: pg_upgrade compares them database by database and refuses to go on when they
		# differ. The locale provider column only exists from PostgreSQL 15 on.
		OLD_LOCALE_PROVIDER=$(su postgres -c "psql -h ${UPGRADE_SOCKET_DIR} -p ${UPGRADE_PORT} -U ${ADMIN_USER} -d template1 -At -c \"SELECT datlocprovider FROM pg_database WHERE datname = 'template0';\"" 2> /dev/null || echo c)
		OLD_ENCODING=$(su postgres -c "psql -h ${UPGRADE_SOCKET_DIR} -p ${UPGRADE_PORT} -U ${ADMIN_USER} -d template1 -At -c \"SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = 'template0';\"")
		OLD_COLLATE=$(su postgres -c "psql -h ${UPGRADE_SOCKET_DIR} -p ${UPGRADE_PORT} -U ${ADMIN_USER} -d template1 -At -c \"SELECT datcollate FROM pg_database WHERE datname = 'template0';\"")
		OLD_CTYPE=$(su postgres -c "psql -h ${UPGRADE_SOCKET_DIR} -p ${UPGRADE_PORT} -U ${ADMIN_USER} -d template1 -At -c \"SELECT datctype FROM pg_database WHERE datname = 'template0';\"")
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

		# Names the locale provider rather than leaving it to the default of this version, which
		# is what the check above assumes: only libc is reproduced here.
		if ${NEW_BINDIR}/initdb --help | grep -q -- --locale-provider
		then
			PROVIDER_ARG=--locale-provider=libc
		else
			PROVIDER_ARG=
		fi

		# Initializes the new cluster, with the superuser of the old one: pg_upgrade requires both
		# clusters to have the same install user, and initdb names it after the operating system
		# user unless told otherwise. pg_upgrade migrates the old catalog into it. Anything
		# left by an interrupted attempt is discarded, since initdb needs an empty folder.
		echo "Initializing PostgreSQL ${NEW_VERSION} at ${PGDATA} (${OLD_ENCODING}, ${OLD_COLLATE})"
		upgrade_save_state initializing
		rm -rf "${PGDATA}"
		mkdir -p "${PGDATA}"
		chown postgres:postgres "${PGDATA}"
		chmod 700 "${PGDATA}"
		su postgres -c "${NEW_BINDIR}/initdb -D ${PGDATA} ${CHECKSUM_ARG} ${PROVIDER_ARG} --username=${ADMIN_USER} --encoding=${OLD_ENCODING} --lc-collate=${OLD_COLLATE} --lc-ctype=${OLD_CTYPE}"

		# Copies the data files when the volume has room for a second copy of them: the old
		# cluster stays intact, so an interrupted upgrade is retried on the next start with
		# nothing lost. Falls back to hard links, which need almost no extra space but leave
		# both clusters sharing data blocks, and the old one unusable.
		RESOLVED_MODE=${UPGRADE_MODE}
		if [ "${RESOLVED_MODE}" = "auto" ]
		then
			OLD_DATA_SIZE=$(du -sk ${OLD_PGDATA} | cut -f1)
			FREE_SIZE=$(df -Pk ${MOUNT_ROOT} | awk 'NR == 2 { print $4 }')
			if [ ${FREE_SIZE} -gt $(( OLD_DATA_SIZE * 12 / 10 )) ]
			then
				RESOLVED_MODE=copy
			else
				RESOLVED_MODE=link
			fi
		fi

		# Upgrades the catalog. pg_upgrade writes its logs and its scripts in the current
		# folder, which has to be writable by the postgres user.
		echo "Running pg_upgrade from ${OLD_VERSION} to ${NEW_VERSION} in ${RESOLVED_MODE} mode"
		if [ "${RESOLVED_MODE}" = "link" ]
		then
			upgrade_save_state linking
		else
			upgrade_save_state copying
		fi
		rm -rf ${UPGRADE_LOG_DIR}
		mkdir -p ${UPGRADE_LOG_DIR}
		chown postgres:postgres ${UPGRADE_LOG_DIR}
		if ! su postgres -c "cd ${UPGRADE_LOG_DIR} && ${NEW_BINDIR}/pg_upgrade --old-bindir=${OLD_BINDIR} --new-bindir=${NEW_BINDIR} --old-datadir=${OLD_PGDATA} --new-datadir=${PGDATA} --username=${ADMIN_USER} --${RESOLVED_MODE}"
		then
			find ${UPGRADE_LOG_DIR} ${PGDATA}/pg_upgrade_output.d -type f \( -name '*.log' -o -name '*.txt' \) 2> /dev/null | while read LOG_FILE
			do
				echo "--- ${LOG_FILE}"
				tail -n 50 ${LOG_FILE}
			done
			# From PostgreSQL 15 on these are written under the new data directory rather than the
			# current folder, and the next attempt discards that directory: they are printed here
			# or they are lost.
			upgrade_fail "pg_upgrade from ${OLD_VERSION} to ${NEW_VERSION} did not finish (see the logs above)."
		fi
		upgrade_save_state migrated

	fi

fi

# Finishes the migration with the cluster running on a private socket only: no TCP, so the
# health check of the container cannot take this transient start for a healthy database and
# send traffic before psql_init.sh takes over.
echo "Finishing PostgreSQL ${NEW_VERSION} migration"
TEMP_HBA=$(mktemp /tmp/pg_hba_XXXXXX.conf)
echo "local all all trust" > ${TEMP_HBA}
chmod 644 ${TEMP_HBA}
rm -f ${PGDATA}/postmaster.pid
su postgres -c "${NEW_BINDIR}/pg_ctl start -D ${PGDATA} -w -t 3600 -o '-c hba_file=${TEMP_HBA} -c listen_addresses= -c port=${UPGRADE_PORT} -c unix_socket_directories=${UPGRADE_SOCKET_DIR}'"

# Sets the admin password when the migrated cluster has none: the old deployment may have
# trusted its local connections, while the configuration psql_init.sh writes asks for a
# password, and psql_configure.sh would wait for a connection it can never make.
HAS_PASSWORD=$(su postgres -c "psql -h ${UPGRADE_SOCKET_DIR} -p ${UPGRADE_PORT} -U ${ADMIN_USER} -d postgres -At -c \"SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = '${ADMIN_USER}';\"")
if [ "${HAS_PASSWORD}" = "f" ]
then
	echo "Setting the password of ${ADMIN_USER}"
	# The password reaches psql through standard input and the statement through a file, so it
	# is in neither the process arguments, which any process in the container can read, nor the
	# statement text, which reaches the server log through the three settings turned off here.
	# psql quotes both values, where a shell would let a quote in either end the literal.
	ALTER_FILE=$(mktemp /tmp/pg_alter_XXXXXX.sql)
	chmod 600 ${ALTER_FILE}
	cat > ${ALTER_FILE} <<-'STATEMENT'
		\prompt pw
		ALTER USER :"name" PASSWORD :'pw';
	STATEMENT
	printf '%s\n' "${ADMIN_PASSWORD}" | \
		PGOPTIONS='-c log_statement=none -c log_min_duration_statement=-1 -c log_min_error_statement=panic' \
		psql -h ${UPGRADE_SOCKET_DIR} -p ${UPGRADE_PORT} -U "${ADMIN_USER}" -d postgres \
			-v ON_ERROR_STOP=1 -v name="${ADMIN_USER}" -f ${ALTER_FILE}
	rm -f ${ALTER_FILE}
fi

# Updates the extensions pg_upgrade kept at the version of the old binaries.
if [ -f ${UPGRADE_LOG_DIR}/update_extensions.sql ]
then
	echo "Updating extensions"
	su postgres -c "psql -h ${UPGRADE_SOCKET_DIR} -p ${UPGRADE_PORT} -U ${ADMIN_USER} -d postgres -v ON_ERROR_STOP=1 -f ${UPGRADE_LOG_DIR}/update_extensions.sql"
fi

su postgres -c "${NEW_BINDIR}/pg_ctl stop -D ${PGDATA} -m fast -w"
rm -f ${TEMP_HBA}

# Records the migration on the volume before anything is dropped: the state file keeps it from
# running again, and the history keeps the trail of what this volume went through. Written here
# and not after the removal below, which in copy mode walks a full second copy of the database
# and is the window an orchestrator is most likely to kill the container in: a kill there would
# otherwise leave a volume holding a finished migration under a phase that is not done, which
# psql_relocate.sh refuses to start on — the data whole and neither image able to bring the job
# up until an operator edits the state file. Recorded first, the worst such a kill leaves is a
# folder still on the volume, which the next run ignores while there is live data to read.
upgrade_save_state done
echo "$(date -Is) PostgreSQL ${OLD_VERSION} migrated to ${NEW_VERSION} (${RESOLVED_MODE})" >> ${MOUNT_ROOT}/.pg_upgrade_history

# Drops the old data. In link mode its files are already shared with the new cluster, so
# only directory entries go away; in copy mode this is the copy to roll back to, so keep it
# with UPGRADE_KEEP_OLD_DATA=true when the space it takes is not a problem.
if [ "${UPGRADE_KEEP_OLD_DATA}" = "true" ]
then
	if [ "${RESOLVED_MODE}" = "move" ]
	then
		echo "Nothing was kept at ${OLD_PGDATA}: the data files were moved, not copied"
	else
		echo "Keeping the old PostgreSQL ${OLD_VERSION} data at ${OLD_PGDATA}"
		if [ "${RESOLVED_MODE}" != "copy" ]
		then
			echo "The old data shares its data files with ${PGDATA}: starting it would corrupt both"
		fi
	fi
else
	echo "Removing the old PostgreSQL ${OLD_VERSION} data at ${OLD_PGDATA}"
	rm -rf "${OLD_PGDATA}"
fi
rm -rf ${UPGRADE_LOG_DIR}
echo "PostgreSQL ${OLD_VERSION} data migrated to ${NEW_VERSION}"


# Rebuilds the planner statistics in the background: pg_upgrade does not carry them over,
# and rebuilding them here would hold the server startup for as long as it takes on a large
# database. Waits for the server psql_init.sh is about to start, as psql_configure.sh does.
if [ "${UPGRADE_ANALYZE}" = "true" ] && [ "${OLD_VERSION}" != "${NEW_VERSION}" ]
then
	(
		# Bounded, and loud when it gives up: the password may not be the one the migrated
		# cluster carries, and an unbounded loop would spend the life of the container spawning
		# a psql a second while the statistics the runbook promises are never rebuilt.
		ANALYZE_ATTEMPT=0
		while !(PGPASSWORD="${ADMIN_PASSWORD}" psql -U "${ADMIN_USER}" -d postgres -c 'SELECT 1;' > /dev/null 2>&1)
		do
			ANALYZE_ATTEMPT=$(( ANALYZE_ATTEMPT + 1 ))
			if [ ${ANALYZE_ATTEMPT} -ge 3600 ]
			then
				echo "Gave up waiting to connect as ${ADMIN_USER}: the planner statistics were NOT rebuilt, and queries will plan on none until vacuumdb --all --analyze-in-stages is run by hand" >&2
				exit 0
			fi
			sleep 1
		done
		echo "Rebuilding the planner statistics after the upgrade"
		PGPASSWORD="${ADMIN_PASSWORD}" vacuumdb --all --analyze-in-stages -U "${ADMIN_USER}" > /dev/null
		echo "Planner statistics rebuilt"
	) &
fi
