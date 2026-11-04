-- The reconcile lives in its own schema, owned by the role that installs it (the
-- admin superuser) and closed to everyone else. It must not be in public: the
-- database owner (the application user) owns public on PostgreSQL 15+, and a
-- schema owner can drop and replace any object in it, which would make the
-- hourly superuser run execute the application's code.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'ldap_reconcile'
               AND nspowner <> (SELECT oid FROM pg_roles WHERE rolname = current_user)) THEN
        RAISE EXCEPTION 'schema ldap_reconcile exists and is not owned by %: refusing to install into it', current_user;
    END IF;
END
$$;
CREATE SCHEMA IF NOT EXISTS ldap_reconcile AUTHORIZATION CURRENT_USER;
REVOKE ALL ON SCHEMA ldap_reconcile FROM PUBLIC;

-- Audit table for all permissions changes (permanent + temporary flows).

CREATE TABLE IF NOT EXISTS ldap_reconcile.permissions_audit (
    id              BIGSERIAL PRIMARY KEY,
    applied_at      TIMESTAMP NOT NULL DEFAULT now(),
    flow            TEXT NOT NULL,    -- permanent_sync | temporary_grant | temporary_revoke
    grantee         TEXT,
    schema_name     TEXT,
    table_name      TEXT,             -- NULL = whole schema
    permission      TEXT,
    action          TEXT NOT NULL,    -- GRANT | REVOKE | CREATE_USER | DROP_USER | ERROR | ...
    source          TEXT,             -- consul_sync | approval_service | cron | boot | manual
    consul_revision TEXT,
    ticket_ref      TEXT,
    approver        TEXT,
    detail          JSONB
);

CREATE INDEX IF NOT EXISTS idx_audit_applied ON ldap_reconcile.permissions_audit(applied_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_grantee ON ldap_reconcile.permissions_audit(grantee, schema_name, table_name);
CREATE INDEX IF NOT EXISTS idx_audit_ticket  ON ldap_reconcile.permissions_audit(ticket_ref) WHERE ticket_ref IS NOT NULL;
-- When each managed user's privileges were last reconciled: the order of the next
-- run, so a run cut short by its time budget continues where it stopped.
CREATE TABLE IF NOT EXISTS ldap_reconcile.privilege_progress (
    username      TEXT PRIMARY KEY,
    reconciled_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_flow    ON ldap_reconcile.permissions_audit(flow, action);
