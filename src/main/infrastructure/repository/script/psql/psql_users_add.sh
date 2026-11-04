#!/bin/sh
#
# Kept for callers that run it by name (the on-demand "update database users" pipeline):
# the users are now reconciled by psql_reconcile_permissions.sh, which this runs.
cd "$(dirname "$0")" || exit 1
RECONCILE_SOURCE="${RECONCILE_SOURCE:-manual}" exec ./psql_reconcile_permissions.sh "$@"
