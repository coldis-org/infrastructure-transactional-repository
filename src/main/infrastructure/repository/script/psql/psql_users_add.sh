#!/bin/sh
#
# Kept for callers that run it by name (the on-demand "update database users" pipeline):
# the users are now reconciled by psql_reconcile_permissions.sh, which this runs.
cd "$(dirname "$0")" || exit 1
# Queued behind a cron or boot run (RECONCILE_STATEMENT_TIMEOUT, 300s by default, plus LDAP)
# instead of failing on the lock. 75: the wait ran out.
RECONCILE_SOURCE="${RECONCILE_SOURCE:-manual}" flock -w "${RECONCILE_LOCK_WAIT:-330}" -E 75 /var/lock/reconcile_permissions.lock ./psql_reconcile_permissions.sh "$@"
status=$?
[ "$status" != 75 ] || echo "psql_users_add: another reconcile is still running after ${RECONCILE_LOCK_WAIT:-330}s; try again later" >&2
exit "$status"
