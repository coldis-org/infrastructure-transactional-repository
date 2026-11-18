#!/bin/sh

# Health check of a streaming replica, for a Nomad script check with check_restart and
# ignore_warnings = true. It answers one question: would a restart fix this replica? Exit codes are
# the ones Nomad and Consul read:
#
#   0  passing: replay runs, or the server is not a standby (promoted), or it does not accept
#      connections yet (starting, replaying up to a consistent state, taking a base backup).
#      Availability is left to another check, so a long start is never cut short.
#   2  critical: replay is paused because one of the settings a standby needs at least as high as
#      its primary is lower than the value the primary recorded in pg_control. A primary restarted
#      with a higher value does that to a running standby, which then keeps serving stale data.
#      A restart fixes it: psql_replica_init.sh raises those settings to the primary's.
#   1  warning, what a restart would not fix: replay paused with every setting at or above the
#      primary's (pg_wal_replay_pause by hand), or a state that cannot be read while the server
#      accepts connections.
#
# Connects through the local socket, which pg_hba.conf trusts, as the admin user.

pg_isready -q || exit 0

# One row: pause state (a server out of recovery reads as running), then the five settings.
ROW=$(psql -X -q -t -A -F '|' -v ON_ERROR_STOP=1 -U "${POSTGRES_ADMIN_USER:-postgres}" -d postgres -c "
	SELECT CASE WHEN pg_is_in_recovery() THEN pg_get_wal_replay_pause_state() ELSE 'not paused' END,
		current_setting('max_connections'), current_setting('max_worker_processes'),
		current_setting('max_wal_senders'), current_setting('max_prepared_transactions'),
		current_setting('max_locks_per_transaction')") \
	|| { echo "The server accepts connections but its replay state cannot be read"; exit 1; }
IFS='|' read -r STATE CONNECTIONS WORKERS SENDERS PREPARED LOCKS <<EOF
${ROW}
EOF
[ "${STATE}" = "not paused" ] && exit 0

# pg_control holds the values the primary last recorded, the ones PostgreSQL checks the standby
# against; pg_controldata speaks the image's pt_BR, hence the C locale.
CONTROL=$(LC_ALL=C pg_controldata "${PGDATA}") \
	|| { echo "WAL replay ${STATE} and pg_control cannot be read"; exit 1; }
LOWER=$(printf '%s\n' "${CONTROL}" | awk -F': *' \
	-v connections="${CONNECTIONS}" -v workers="${WORKERS}" -v senders="${SENDERS}" \
	-v prepared="${PREPARED}" -v locks="${LOCKS}" '
	$1 == "max_connections setting" && $2 + 0 > connections + 0 { print "max_connections" }
	$1 == "max_worker_processes setting" && $2 + 0 > workers + 0 { print "max_worker_processes" }
	$1 == "max_wal_senders setting" && $2 + 0 > senders + 0 { print "max_wal_senders" }
	$1 == "max_prepared_xacts setting" && $2 + 0 > prepared + 0 { print "max_prepared_transactions" }
	$1 == "max_locks_per_xact setting" && $2 + 0 > locks + 0 { print "max_locks_per_transaction" }' \
	| paste -s -d, -)
if [ -n "${LOWER}" ]
then
	echo "WAL replay ${STATE}: ${LOWER} below the primary's; a restart raises them"
	exit 2
fi
echo "WAL replay ${STATE} with every setting at or above the primary's; a restart would not help"
exit 1
