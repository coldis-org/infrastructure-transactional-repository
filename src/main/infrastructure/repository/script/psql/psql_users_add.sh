#!/bin/sh
#
# Kept for callers that run it by name (the on-demand "update database users" pipeline):
# the users are now reconciled by psql_reconcile_permissions.sh, which this runs.
cd "$(dirname "$0")" || exit 1
# Queued behind a cron or boot run (up to its statement timeout) instead of failing on the lock.
RECONCILE_SOURCE="${RECONCILE_SOURCE:-manual}" exec flock -w 330 /var/lock/reconcile_permissions.lock ./psql_reconcile_permissions.sh "$@"
