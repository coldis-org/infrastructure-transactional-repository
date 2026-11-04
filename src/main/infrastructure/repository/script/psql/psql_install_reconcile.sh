#!/bin/sh
#
# Installs the permissions reconcile (sql/permissions_audit.sql, sql/reconcile_permissions.sql)
# and records the md5 of the function's SQL in its comment: psql_reconcile_permissions.sh only
# runs a function that matches the image's SQL, and calls this to repair a mismatch. Called by
# psql_configure.sh at boot. Uses POSTGRES_ADMIN_USER, POSTGRES_ADMIN_PASSWORD and
# POSTGRES_DEFAULT_DATABASE. psql -f fails on a missing file, so an incomplete image installs
# nothing.

SQL_DIR="$(cd "$(dirname "$0")" && pwd)/sql"
# search_path pinned: public belongs to the database owner on 15+.
PGOPTIONS="-c search_path=pg_catalog" PGPASSWORD="${POSTGRES_ADMIN_PASSWORD:-postgres}" \
	psql -X -q -v ON_ERROR_STOP=1 -U "${POSTGRES_ADMIN_USER:-postgres}" -d "${POSTGRES_DEFAULT_DATABASE:?}" \
	-v checksum="$(md5sum "${SQL_DIR}/reconcile_permissions.sql" | cut -d' ' -f1)" \
	-f "${SQL_DIR}/permissions_audit.sql" -f "${SQL_DIR}/reconcile_permissions.sql" -f - <<'SQL'
SELECT format('COMMENT ON FUNCTION ldap_reconcile.reconcile_permissions(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[]) IS %L', 'sql md5 ' || :'checksum') \gexec
SQL
