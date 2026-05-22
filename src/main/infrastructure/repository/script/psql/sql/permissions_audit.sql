-- Audit table for all permissions changes (permanent + temporary flows).

CREATE TABLE IF NOT EXISTS permissions_audit (
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

CREATE INDEX IF NOT EXISTS idx_audit_applied ON permissions_audit(applied_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_grantee ON permissions_audit(grantee, schema_name, table_name);
CREATE INDEX IF NOT EXISTS idx_audit_ticket  ON permissions_audit(ticket_ref) WHERE ticket_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_flow    ON permissions_audit(flow, action);
