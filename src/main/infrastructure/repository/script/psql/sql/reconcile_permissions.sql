-- Reconciles LDAP-managed database users and their privileges with the desired
-- state the wrapper (psql_reconcile_permissions.sh) resolves from the PSQL_*
-- variables and LDAP. Replaces psql_users_add, psql_users_remove and
-- psql_users_alter_group.
--
-- Input, as text with one tab-separated row per line:
--   configuration_lines   kind, object, table, ldap_group
--              kind read|write: object is a schema, table empty for the whole
--              schema or a table name; kind member: object is a group role.
--   membership_lines  ldap_group, user (a group with no members has no line: it is a
--              valid, empty group).
--
-- Ownership: a role is managed when it is a direct member of ldap_managed (NOLOGIN);
-- a role granted a managed user's role is not managed through it.
-- Only managed roles are created, changed or dropped. Login roles are adopted
-- when they are in LDAP, or when they hold a privilege on a configured read
-- schema (the population psql_users_remove used to consider). Superusers,
-- replication and bypassrls roles, pg_* roles and protected_role_names are never
-- adopted, and the schema-privilege rule only applies on the first run.
-- ldap_reconcile.permissions_audit is history only. With drops disabled, a managed
-- user no longer in LDAP keeps the role and loses the configured access.
--
-- Privileges are compared with the direct grants in the catalogs and only the
-- difference is granted or revoked, within the configured schemas (and the
-- database's CONNECT/TEMPORARY/CREATE). Grants on other schemas are untouched.
--   read   database CONNECT, TEMPORARY; schema USAGE; SELECT on every table
--          (or the listed ones); SELECT on sequences; EXECUTE on functions.
--   write  database CONNECT, TEMPORARY, CREATE; ALL on schema, tables,
--          sequences, functions.
--   write on listed tables (PSQL_WRITE_SCHEMA_<s>_TABLE_<t>): read on the schema
--          as above, without SELECT on the other tables unless a read mapping
--          gives it; ALL on the listed tables and on their own sequences.
--   none   everything held directly on that schema's objects is revoked.
--
-- Errors: bad input raises and rolls the whole run back. A database error on
-- one user (a role that cannot be dropped, a conflicting grant, a lock timeout)
-- rolls back only that user's step, in its own subtransaction, and is reported
-- as an ERROR row (and recorded in permissions_audit); every other user is
-- still reconciled.

CREATE OR REPLACE FUNCTION ldap_reconcile.reconcile_permissions(
    configuration_lines         TEXT,
    membership_lines        TEXT,
    run_source         TEXT,
    owner_fallback TEXT,
    drops_allowed    BOOLEAN,
    protected_role_names      TEXT[]
)
RETURNS TABLE(action TEXT, username TEXT, detail TEXT)
LANGUAGE plpgsql
-- Only the catalog and this session's temp tables: everything in ldap_reconcile is
-- qualified, and no schema a configured user could write is searched.
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    -- What the old scripts created (quoted), minus anything unsafe to carry around.
    valid_name_pattern     CONSTANT TEXT := '^[A-Za-z0-9_][A-Za-z0-9_.-]*$';
    valid_identifier_pattern    CONSTANT TEXT := '^[a-z_][a-z0-9_]*$';
    all_table_privileges   TEXT[] := ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'];
    all_sequence_privileges     CONSTANT TEXT[] := ARRAY['USAGE','SELECT','UPDATE'];
    owner_role       TEXT;
    database_name    TEXT := current_database();
    config_row    RECORD;
    member_row    RECORD;
    role_row      RECORD;
    schema_row    RECORD;
    relation_row  RECORD;
    function_row  RECORD;
    group_row     RECORD;
    desired_privileges     TEXT[];
    held_privileges      TEXT[];
    privilege        TEXT;
    grant_row     RECORD;
    access_level       TEXT;
    read_tables      TEXT[];
    write_tables     TEXT[];
    is_first_run   BOOLEAN;
    is_in_ldap   BOOLEAN;
    run_started      TIMESTAMPTZ := clock_timestamp();
    time_budget      INTERVAL;
    processed_count  INT := 0;
    deferred_count   INT := 0;
    cut_short        BOOLEAN;
    hard_ceiling     INTERVAL;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('reconcile_permissions'));
    -- Time budget for the per-user privilege step (unset = none), set by the caller
    -- below its statement timeout, so a large run commits part of the work instead of
    -- being cancelled and rolled back whole.
    time_budget := NULLIF(current_setting('reconcile.time_budget', true), '')::INTERVAL;
    -- 90% of the statement timeout stops any user's step, the first one too, so the rest
    -- of the run (drops, revocations, other users) still commits.
    hard_ceiling := NULLIF(current_setting('statement_timeout'), '0')::INTERVAL * 0.9;
    IF current_setting('server_version_num')::INT >= 170000 THEN
        all_table_privileges := array_append(all_table_privileges, 'MAINTAIN');
    END IF;

    owner_role := COALESCE(NULLIF(owner_fallback, ''), current_user::TEXT);
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = owner_role) THEN
        RAISE EXCEPTION 'reconcile_permissions: owner fallback role % does not exist', owner_role;
    END IF;

    -- Input.
    CREATE TEMP TABLE _config(kind TEXT, object TEXT, tbl TEXT, ldap_group TEXT) ON COMMIT DROP;
    CREATE TEMP TABLE _members(ldap_group TEXT, username TEXT) ON COMMIT DROP;
    -- Results go through a table, not RETURN NEXT: a row returned inside a
    -- subtransaction that is rolled back would still reach the caller.
    CREATE TEMP TABLE _out(ord BIGSERIAL, action TEXT, username TEXT, detail TEXT) ON COMMIT DROP;
    INSERT INTO _config
        SELECT split_part(line, E'\t', 1), split_part(line, E'\t', 2),
               NULLIF(split_part(line, E'\t', 3), ''), split_part(line, E'\t', 4)
          FROM regexp_split_to_table(COALESCE(configuration_lines, ''), E'\n') AS line WHERE line <> '';
    INSERT INTO _members
        SELECT split_part(line, E'\t', 1), split_part(line, E'\t', 2)
          FROM regexp_split_to_table(COALESCE(membership_lines, ''), E'\n') AS line WHERE line <> '';
    FOR config_row IN SELECT * FROM _config LOOP
        IF config_row.kind NOT IN ('read', 'write', 'member') OR config_row.object !~ valid_identifier_pattern
           OR (config_row.tbl IS NOT NULL AND config_row.tbl !~ valid_identifier_pattern) OR config_row.ldap_group = ''
           OR (config_row.kind = 'member' AND config_row.tbl IS NOT NULL)
           OR (config_row.kind IN ('read', 'write') AND (config_row.object IN ('ldap_reconcile', 'information_schema')
                                                       OR config_row.object LIKE 'pg\_%')) THEN
            RAISE EXCEPTION 'reconcile_permissions: invalid configuration row (%, %, %, %)', config_row.kind, config_row.object, config_row.tbl, config_row.ldap_group;
        END IF;
    END LOOP;
    FOR member_row IN SELECT * FROM _members LOOP
        IF member_row.username !~ valid_name_pattern OR octet_length(member_row.username) > 63 OR NOT EXISTS (SELECT 1 FROM _config c WHERE c.ldap_group = member_row.ldap_group) THEN
            RAISE EXCEPTION 'reconcile_permissions: invalid member row (%, %)', member_row.ldap_group, member_row.username;
        END IF;
    END LOOP;

    -- Desired state: per user and configured schema, the level (write > read)
    -- and, for read, the tables (NULL = every table).
    CREATE TEMP TABLE _wanted ON COMMIT DROP AS
        SELECT m.username, c.object AS schema_name,
               CASE WHEN bool_or(c.kind = 'write' AND c.tbl IS NULL) THEN 'write' ELSE 'read' END AS level,
               -- read: NULL = every table; otherwise the listed ones (maybe none).
               CASE WHEN bool_or(c.kind = 'write' AND c.tbl IS NULL) OR bool_or(c.kind = 'read' AND c.tbl IS NULL) THEN NULL
                    ELSE COALESCE(array_agg(DISTINCT c.tbl) FILTER (WHERE c.kind = 'read'), ARRAY[]::TEXT[]) END AS tables,
               COALESCE(array_agg(DISTINCT c.tbl) FILTER (WHERE c.kind = 'write' AND c.tbl IS NOT NULL), ARRAY[]::TEXT[]) AS write_tables
          FROM _config c JOIN _members m ON m.ldap_group = c.ldap_group
         WHERE c.kind IN ('read', 'write')
         GROUP BY m.username, c.object;
    -- The managed population: users with at least one read or write permission. A
    -- group role mapping (member) neither creates nor keeps a user on its own.
    CREATE TEMP TABLE _target ON COMMIT DROP AS SELECT DISTINCT w.username FROM _wanted w;
    CREATE TEMP TABLE _schemas ON COMMIT DROP AS
        SELECT DISTINCT c.object AS schema_name, n.oid AS schema_oid
          FROM _config c JOIN pg_namespace n ON n.nspname = c.object WHERE c.kind IN ('read', 'write');

    -- The ownership marker. Its creation is the first run.
    is_first_run := NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ldap_managed');
    IF is_first_run THEN
        CREATE ROLE ldap_managed NOLOGIN;
        INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
        VALUES ('permanent_sync', 'CREATE_ROLE', run_source, 'ldap_managed', '{"reason": "ownership marker"}');
    END IF;

    -- Roles that may never be managed.
    CREATE TEMP TABLE _protected ON COMMIT DROP AS
        SELECT a.oid, a.rolname FROM pg_roles a
         WHERE a.rolsuper OR a.rolreplication OR a.rolbypassrls OR a.rolcreaterole OR a.rolcreatedb OR a.rolname LIKE 'pg\_%'
            OR a.rolname = 'ldap_managed' OR a.rolname = owner_role OR a.rolname = current_user
            OR a.rolname = ANY(COALESCE(protected_role_names, ARRAY[]::TEXT[]));

    -- A group role (PSQL_ALTER_GROUP_*) must be a plain NOLOGIN role with no
    -- privileged attribute and no membership in a privileged or predefined role:
    -- membership in it is handed to whoever LDAP lists.
    FOR group_row IN
        SELECT DISTINCT c.object AS role_name FROM _config c
          JOIN pg_roles a ON a.rolname = c.object
         WHERE c.kind = 'member'
           AND (a.rolsuper OR a.rolcreaterole OR a.rolcreatedb OR a.rolreplication OR a.rolbypassrls OR a.rolcanlogin
                OR a.rolname LIKE 'pg\_%' OR a.oid IN (SELECT oid FROM _protected)
                OR EXISTS (SELECT 1 FROM _protected protected_role
                            WHERE protected_role.oid <> a.oid AND pg_has_role(a.oid, protected_role.oid, 'MEMBER'))
                OR EXISTS (SELECT 1 FROM pg_roles privileged
                            WHERE privileged.oid <> a.oid
                              AND (privileged.rolsuper OR privileged.rolcreaterole OR privileged.rolcreatedb
                                   OR privileged.rolreplication OR privileged.rolbypassrls OR privileged.rolname LIKE 'pg\_%')
                              AND pg_has_role(a.oid, privileged.oid, 'MEMBER')))
    LOOP
        -- Reported, and its membership left alone; everything else is still reconciled.
        INSERT INTO _out(action, username, detail)
        VALUES ('ERROR', NULL, 'group role ' || group_row.role_name || ' is privileged or a login role; its membership is not managed');
        DELETE FROM _config c WHERE c.kind = 'member' AND c.object = group_row.role_name;
    END LOOP;

    -- Adoption: login roles in LDAP that are not managed yet; on the first run
    -- only, also login roles with a privilege on a schema configured for a
    -- whole-schema read, when drops are enabled: exactly the users
    -- psql_users_remove considered (it touched nobody with SKIP_DELETE=true, and
    -- never matched a _TABLE_ mapping). After that, a role granted access by
    -- other means (a migration, a DBA) is never taken over.
    FOR role_row IN
        SELECT a.rolname FROM pg_roles a
         WHERE a.rolcanlogin
           AND a.oid NOT IN (SELECT oid FROM _protected)
           AND NOT EXISTS (SELECT 1 FROM pg_auth_members managed_by WHERE managed_by.member = a.oid AND managed_by.roleid = 'ldap_managed'::regrole)
           AND (a.rolname IN (SELECT tg.username FROM _target tg)
                OR (is_first_run AND drops_allowed AND EXISTS (SELECT 1 FROM pg_namespace n, aclexplode(n.nspacl) x
                            WHERE x.grantee = a.oid
                              AND n.nspname IN (SELECT c.object FROM _config c WHERE c.kind = 'read' AND c.tbl IS NULL))))
         ORDER BY a.rolname
    LOOP
        BEGIN
            EXECUTE format('GRANT ldap_managed TO %I', role_row.rolname);
            INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
            VALUES ('permanent_sync', 'ADOPT_USER', run_source, role_row.rolname, '{"reason": "existing login role in LDAP or on a configured read schema"}');
            INSERT INTO _out(action, username, detail) VALUES ('ADOPT_USER', role_row.rolname, NULL);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
            VALUES ('permanent_sync', 'ERROR', run_source, role_row.rolname, jsonb_build_object('op', 'adopt', 'sqlstate', SQLSTATE, 'sqlerrm', SQLERRM));
            INSERT INTO _out(action, username, detail) VALUES ('ERROR', role_row.rolname, 'adopt: ' || SQLERRM);
        END;
    END LOOP;

    -- Users in LDAP that do not exist yet.
    FOR role_row IN SELECT tg.username FROM _target tg WHERE NOT EXISTS (SELECT 1 FROM pg_roles a WHERE a.rolname = tg.username) ORDER BY 1 LOOP
        BEGIN
            EXECUTE format('CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION IN ROLE ldap_managed', role_row.username);
            INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
            VALUES ('permanent_sync', 'CREATE_USER', run_source, role_row.username, NULL);
            INSERT INTO _out(action, username, detail) VALUES ('CREATE_USER', role_row.username, NULL);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
            VALUES ('permanent_sync', 'ERROR', run_source, role_row.username, jsonb_build_object('op', 'create', 'sqlstate', SQLSTATE, 'sqlerrm', SQLERRM));
            INSERT INTO _out(action, username, detail) VALUES ('ERROR', role_row.username, 'create: ' || SQLERRM);
        END;
    END LOOP;

    -- Managed roles no longer in LDAP.
    FOR role_row IN
        SELECT a.rolname FROM pg_roles a
         WHERE EXISTS (SELECT 1 FROM pg_auth_members managed_by WHERE managed_by.member = a.oid AND managed_by.roleid = 'ldap_managed'::regrole) AND a.rolname <> 'ldap_managed'
           AND a.oid NOT IN (SELECT oid FROM _protected)
           AND a.rolname NOT IN (SELECT tg.username FROM _target tg)
         ORDER BY a.rolname
    LOOP
        -- Drops can wait on locks: past the ceiling the rest wait for the next run.
        IF hard_ceiling IS NOT NULL AND clock_timestamp() - run_started > hard_ceiling THEN
            deferred_count := deferred_count + 1;
            CONTINUE;
        END IF;
        IF drops_allowed THEN
            BEGIN
                -- Objects go to the default (application) user; never to a superuser.
                IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = owner_role AND rolsuper) THEN
                    RAISE EXCEPTION 'no non-superuser owner to reassign % objects to (POSTGRES_DEFAULT_USER is empty or a superuser)', role_row.rolname;
                END IF;
                -- A SECURITY DEFINER routine would run as the new owner (the application
                -- user) for anyone allowed to call it: it is made SECURITY INVOKER first.
                FOR function_row IN SELECT p.oid::regprocedure::TEXT AS signature FROM pg_proc p
                                     WHERE p.proowner = (SELECT oid FROM pg_roles WHERE rolname = role_row.rolname) AND p.prosecdef ORDER BY 1 LOOP
                    EXECUTE format('ALTER ROUTINE %s SECURITY INVOKER', function_row.signature);
                    INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, table_name)
                    VALUES ('permanent_sync', 'SECURITY_INVOKER', run_source, role_row.rolname, function_row.signature);
                    INSERT INTO _out(action, username, detail) VALUES ('SECURITY_INVOKER', role_row.rolname, function_row.signature);
                END LOOP;
                -- Views and rules run with their owner's rights: after the reassign, a
                -- relation the user granted to others would act with the application
                -- user's access. Every grant to another role on the user's relations,
                -- column grants included, is revoked first (REVOKE ALL on the table also
                -- revokes its column privileges).
                FOR relation_row IN SELECT DISTINCT c.oid::regclass::TEXT AS relation_name, x.grantee
                                      FROM pg_class c
                                      CROSS JOIN LATERAL (SELECT acl.grantee FROM aclexplode(c.relacl) acl
                                                          UNION SELECT acl.grantee FROM pg_attribute att, aclexplode(att.attacl) acl
                                                                 WHERE att.attrelid = c.oid AND att.attacl IS NOT NULL) x
                                     WHERE c.relowner = (SELECT oid FROM pg_roles WHERE rolname = role_row.rolname)
                                       AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND x.grantee <> c.relowner ORDER BY 1 LOOP
                    EXECUTE format('REVOKE ALL ON TABLE %s FROM %s', relation_row.relation_name,
                                   CASE WHEN relation_row.grantee = 0 THEN 'PUBLIC' ELSE relation_row.grantee::regrole::TEXT END);
                    INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, table_name, detail)
                    VALUES ('permanent_sync', 'REVOKE_OBJECT_GRANTS', run_source, role_row.rolname, relation_row.relation_name,
                            jsonb_build_object('from', CASE WHEN relation_row.grantee = 0 THEN 'PUBLIC' ELSE relation_row.grantee::regrole::TEXT END));
                    INSERT INTO _out(action, username, detail) VALUES ('REVOKE_OBJECT_GRANTS', role_row.rolname, relation_row.relation_name);
                END LOOP;
                EXECUTE format('REASSIGN OWNED BY %I TO %I', role_row.rolname, owner_role);
                EXECUTE format('DROP OWNED BY %I', role_row.rolname);
                EXECUTE format('DROP ROLE %I', role_row.rolname);
                DELETE FROM ldap_reconcile.privilege_progress progress WHERE progress.username = role_row.rolname;
                INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
                VALUES ('permanent_sync', 'DROP_USER', run_source, role_row.rolname, jsonb_build_object('reassigned_to', owner_role));
                INSERT INTO _out(action, username, detail) VALUES ('DROP_USER', role_row.rolname, 'objects reassigned to ' || owner_role);
            EXCEPTION WHEN OTHERS THEN
                INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
                VALUES ('permanent_sync', 'ERROR', run_source, role_row.rolname, jsonb_build_object('op', 'drop', 'sqlstate', SQLSTATE, 'sqlerrm', SQLERRM));
                INSERT INTO _out(action, username, detail) VALUES ('ERROR', role_row.rolname, 'drop: ' || SQLERRM);
            END;
        ELSE
            INSERT INTO _out(action, username, detail) VALUES ('KEEP_USER', role_row.rolname, 'not in LDAP; drops disabled (SKIP_DELETE): role kept, configured access revoked');
        END IF;
    END LOOP;

    -- Privileges of managed users: those in LDAP get the desired state; those
    -- kept although not in LDAP (drops disabled) get none of the configured access.
    -- Least recently reconciled first: when the time budget runs out, the users left
    -- are the first ones of the next run. At least one user is always done.
    FOR role_row IN
        SELECT a.rolname, a.oid FROM pg_roles a
          LEFT JOIN ldap_reconcile.privilege_progress progress ON progress.username = a.rolname
         WHERE EXISTS (SELECT 1 FROM pg_auth_members managed_by WHERE managed_by.member = a.oid AND managed_by.roleid = 'ldap_managed'::regrole) AND a.rolname <> 'ldap_managed'
           AND a.oid NOT IN (SELECT oid FROM _protected)
         -- Users no longer in LDAP (kept, drops disabled) first: their revocation is never deferred.
         ORDER BY a.rolname IN (SELECT tg.username FROM _target tg), progress.reconciled_at NULLS FIRST, a.rolname
    LOOP
        cut_short := false;
        IF (time_budget IS NOT NULL AND processed_count > 0 AND clock_timestamp() - run_started > time_budget)
           OR (hard_ceiling IS NOT NULL AND clock_timestamp() - run_started > hard_ceiling) THEN
            deferred_count := deferred_count + 1;
            CONTINUE;
        END IF;
        processed_count := processed_count + 1;
        BEGIN
            is_in_ldap := role_row.rolname IN (SELECT tg.username FROM _target tg);
            -- Database.
            desired_privileges := CASE WHEN is_in_ldap THEN ARRAY['CONNECT', 'TEMPORARY'] ELSE ARRAY[]::TEXT[] END;
            IF EXISTS (SELECT 1 FROM _wanted w WHERE w.username = role_row.rolname AND w.level = 'write') THEN
                desired_privileges := array_append(desired_privileges, 'CREATE');
            END IF;
            SELECT COALESCE(array_agg(x.privilege_type), ARRAY[]::TEXT[]) INTO held_privileges
              FROM pg_database d, aclexplode(d.datacl) x WHERE d.datname = database_name AND x.grantee = role_row.oid;
            FOREACH privilege IN ARRAY desired_privileges LOOP
                IF NOT privilege = ANY(held_privileges) THEN
                    EXECUTE format('GRANT %s ON DATABASE %I TO %I', privilege, database_name, role_row.rolname);
                    INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, permission, detail)
                    VALUES ('permanent_sync', 'GRANT', run_source, role_row.rolname, privilege, jsonb_build_object('database', database_name));
                    INSERT INTO _out(action, username, detail) VALUES ('GRANT', role_row.rolname, privilege || ' ON DATABASE ' || database_name);
                END IF;
            END LOOP;
            FOR privilege IN SELECT unnest(held_privileges) INTERSECT SELECT unnest(ARRAY['CONNECT','TEMPORARY','CREATE']) EXCEPT SELECT unnest(desired_privileges) LOOP
                -- Revoked once per grantor. A grant made by another role (with grant option) is
                -- revoked as that role: a revoke by the owner would leave it in place while the run
                -- reports it revoked. A failure (that role cannot see the object) is this user's ERROR.
                FOR grant_row IN SELECT DISTINCT x.grantor::regrole::TEXT AS grantor_name, x.grantor = d.datdba AS by_owner
                                   FROM pg_database d, aclexplode(d.datacl) x WHERE d.datname = database_name AND x.grantee = role_row.oid AND x.privilege_type = privilege LOOP
                    IF NOT grant_row.by_owner THEN
                        EXECUTE format('SET ROLE %s', grant_row.grantor_name);
                    END IF;
                    EXECUTE format('REVOKE %s ON DATABASE %I FROM %I', privilege, database_name, role_row.rolname);
                    RESET ROLE;
                END LOOP;
                INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, permission, detail)
                VALUES ('permanent_sync', 'REVOKE', run_source, role_row.rolname, privilege, jsonb_build_object('database', database_name));
                INSERT INTO _out(action, username, detail) VALUES ('REVOKE', role_row.rolname, privilege || ' ON DATABASE ' || database_name);
            END LOOP;

            -- Each configured schema that exists.
            FOR schema_row IN SELECT sc.schema_name, sc.schema_oid FROM _schemas sc ORDER BY 1 LOOP
                SELECT w.level, w.tables, w.write_tables INTO access_level, read_tables, write_tables
                  FROM _wanted w WHERE w.username = role_row.rolname AND w.schema_name = schema_row.schema_name;
                access_level := COALESCE(access_level, 'none');

                -- Schema.
                desired_privileges := CASE access_level WHEN 'write' THEN ARRAY['USAGE','CREATE'] WHEN 'read' THEN ARRAY['USAGE'] ELSE ARRAY[]::TEXT[] END;
                SELECT COALESCE(array_agg(x.privilege_type), ARRAY[]::TEXT[]) INTO held_privileges
                  FROM pg_namespace n, aclexplode(n.nspacl) x WHERE n.oid = schema_row.schema_oid AND x.grantee = role_row.oid;
                FOR privilege IN SELECT unnest(desired_privileges) EXCEPT SELECT unnest(held_privileges) LOOP
                    EXECUTE format('GRANT %s ON SCHEMA %I TO %I', privilege, schema_row.schema_name, role_row.rolname);
                    INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, schema_name, permission)
                    VALUES ('permanent_sync', 'GRANT', run_source, role_row.rolname, schema_row.schema_name, privilege);
                    INSERT INTO _out(action, username, detail) VALUES ('GRANT', role_row.rolname, privilege || ' ON SCHEMA ' || schema_row.schema_name);
                END LOOP;
                FOR privilege IN SELECT unnest(held_privileges) EXCEPT SELECT unnest(desired_privileges) LOOP
                    -- Revoked once per grantor. A grant made by another role (with grant option) is
                    -- revoked as that role: a revoke by the owner would leave it in place while the run
                    -- reports it revoked. A failure (that role cannot see the object) is this user's ERROR.
                    FOR grant_row IN SELECT DISTINCT x.grantor::regrole::TEXT AS grantor_name, x.grantor = n.nspowner AS by_owner
                                       FROM pg_namespace n, aclexplode(n.nspacl) x WHERE n.oid = schema_row.schema_oid AND x.grantee = role_row.oid AND x.privilege_type = privilege LOOP
                        IF NOT grant_row.by_owner THEN
                            EXECUTE format('SET ROLE %s', grant_row.grantor_name);
                        END IF;
                        EXECUTE format('REVOKE %s ON SCHEMA %I FROM %I', privilege, schema_row.schema_name, role_row.rolname);
                        RESET ROLE;
                    END LOOP;
                    INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, schema_name, permission)
                    VALUES ('permanent_sync', 'REVOKE', run_source, role_row.rolname, schema_row.schema_name, privilege);
                    INSERT INTO _out(action, username, detail) VALUES ('REVOKE', role_row.rolname, privilege || ' ON SCHEMA ' || schema_row.schema_name);
                END LOOP;

                -- Tables, views, materialized views, foreign and partitioned tables; sequences.
                FOR relation_row IN
                    SELECT c.oid AS rel_oid, c.relname, c.relkind, schema_row.schema_name AS schema_name
                      FROM pg_class c WHERE c.relnamespace = schema_row.schema_oid AND c.relkind IN ('r','p','v','m','f','S')
                     ORDER BY c.relname
                LOOP
                    -- The budget also stops a long step midway (not the first user's): that
                    -- user's step is rolled back and goes first next run.
                    IF (time_budget IS NOT NULL AND processed_count > 1 AND clock_timestamp() - run_started > time_budget)
                       OR (hard_ceiling IS NOT NULL AND clock_timestamp() - run_started > hard_ceiling) THEN
                        RAISE EXCEPTION USING ERRCODE = 'P0B01', MESSAGE = 'time budget reached';
                    END IF;
                    IF relation_row.relkind = 'S' THEN
                        desired_privileges := CASE
                            WHEN access_level = 'write' THEN all_sequence_privileges
                            -- A single-table writer gets the sequences of its tables only.
                            WHEN access_level = 'read' AND EXISTS (
                                SELECT 1 FROM pg_depend d JOIN pg_class owning ON owning.oid = d.refobjid
                                 WHERE d.classid = 'pg_class'::regclass AND d.objid = relation_row.rel_oid
                                   AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
                                   AND owning.relnamespace = schema_row.schema_oid AND owning.relname = ANY(write_tables))
                                THEN all_sequence_privileges
                            WHEN access_level = 'read' THEN ARRAY['SELECT']
                            ELSE ARRAY[]::TEXT[] END;
                    ELSE
                        desired_privileges := CASE
                            WHEN access_level = 'write' THEN all_table_privileges
                            WHEN access_level = 'read' AND relation_row.relname = ANY(write_tables) THEN all_table_privileges
                            WHEN access_level = 'read' AND (read_tables IS NULL OR relation_row.relname = ANY(read_tables)) THEN ARRAY['SELECT']
                            ELSE ARRAY[]::TEXT[] END;
                    END IF;
                    SELECT COALESCE(array_agg(x.privilege_type), ARRAY[]::TEXT[]) INTO held_privileges
                      FROM pg_class c, aclexplode(c.relacl) x WHERE c.oid = relation_row.rel_oid AND x.grantee = role_row.oid;
                    FOR privilege IN SELECT unnest(desired_privileges) EXCEPT SELECT unnest(held_privileges) LOOP
                        EXECUTE format('GRANT %s ON %s %I.%I TO %I', privilege, CASE WHEN relation_row.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END,
                                       relation_row.schema_name, relation_row.relname, role_row.rolname);
                        INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, schema_name, table_name, permission)
                        VALUES ('permanent_sync', 'GRANT', run_source, role_row.rolname, relation_row.schema_name, relation_row.relname, privilege);
                        INSERT INTO _out(action, username, detail) VALUES ('GRANT', role_row.rolname, privilege || ' ON ' || relation_row.schema_name || '.' || relation_row.relname);
                    END LOOP;
                    FOR privilege IN SELECT unnest(held_privileges) EXCEPT SELECT unnest(desired_privileges) LOOP
                        -- Revoked once per grantor. A grant made by another role (with grant option) is
                        -- revoked as that role: a revoke by the owner would leave it in place while the run
                        -- reports it revoked. A failure (that role cannot see the object) is this user's ERROR.
                        FOR grant_row IN SELECT DISTINCT x.grantor::regrole::TEXT AS grantor_name, x.grantor = c.relowner AS by_owner
                                           FROM pg_class c, aclexplode(c.relacl) x WHERE c.oid = relation_row.rel_oid AND x.grantee = role_row.oid AND x.privilege_type = privilege LOOP
                            IF NOT grant_row.by_owner THEN
                                EXECUTE format('SET ROLE %s', grant_row.grantor_name);
                            END IF;
                            EXECUTE format('REVOKE %s ON %s %I.%I FROM %I', privilege, CASE WHEN relation_row.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END,
                                       relation_row.schema_name, relation_row.relname, role_row.rolname);
                            RESET ROLE;
                        END LOOP;
                        INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, schema_name, table_name, permission)
                        VALUES ('permanent_sync', 'REVOKE', run_source, role_row.rolname, relation_row.schema_name, relation_row.relname, privilege);
                        INSERT INTO _out(action, username, detail) VALUES ('REVOKE', role_row.rolname, privilege || ' ON ' || relation_row.schema_name || '.' || relation_row.relname);
                    END LOOP;
                END LOOP;

            END LOOP;

            FOR function_row IN
                SELECT p.oid AS fn_oid, p.oid::regprocedure::TEXT AS signature, sc.schema_name
                  FROM pg_proc p JOIN _schemas sc ON sc.schema_oid = p.pronamespace
                 WHERE p.prokind = 'f'
                 ORDER BY 2
            LOOP
                IF (time_budget IS NOT NULL AND processed_count > 1 AND clock_timestamp() - run_started > time_budget)
                   OR (hard_ceiling IS NOT NULL AND clock_timestamp() - run_started > hard_ceiling) THEN
                    RAISE EXCEPTION USING ERRCODE = 'P0B01', MESSAGE = 'time budget reached';
                END IF;
                SELECT COALESCE(w.level, 'none') INTO access_level
                  FROM (SELECT 1) one LEFT JOIN _wanted w ON w.username = role_row.rolname AND w.schema_name = function_row.schema_name;
                desired_privileges := CASE WHEN access_level IN ('read', 'write') THEN ARRAY['EXECUTE'] ELSE ARRAY[]::TEXT[] END;
                SELECT COALESCE(array_agg(x.privilege_type), ARRAY[]::TEXT[]) INTO held_privileges
                  FROM pg_proc p, aclexplode(p.proacl) x WHERE p.oid = function_row.fn_oid AND x.grantee = role_row.oid;
                FOR privilege IN SELECT unnest(desired_privileges) EXCEPT SELECT unnest(held_privileges) LOOP
                    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', function_row.signature, role_row.rolname);
                    INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, schema_name, table_name, permission)
                    VALUES ('permanent_sync', 'GRANT', run_source, role_row.rolname, function_row.schema_name, function_row.signature, 'EXECUTE');
                    INSERT INTO _out(action, username, detail) VALUES ('GRANT', role_row.rolname, 'EXECUTE ON ' || function_row.signature);
                END LOOP;
                FOR privilege IN SELECT unnest(held_privileges) EXCEPT SELECT unnest(desired_privileges) LOOP
                    -- Revoked once per grantor. A grant made by another role (with grant option) is
                    -- revoked as that role: a revoke by the owner would leave it in place while the run
                    -- reports it revoked. A failure (that role cannot see the object) is this user's ERROR.
                    FOR grant_row IN SELECT DISTINCT x.grantor::regrole::TEXT AS grantor_name, x.grantor = p.proowner AS by_owner
                                       FROM pg_proc p, aclexplode(p.proacl) x WHERE p.oid = function_row.fn_oid AND x.grantee = role_row.oid AND x.privilege_type = privilege LOOP
                        IF NOT grant_row.by_owner THEN
                            EXECUTE format('SET ROLE %s', grant_row.grantor_name);
                        END IF;
                        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM %I', function_row.signature, role_row.rolname);
                        RESET ROLE;
                    END LOOP;
                    INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, schema_name, table_name, permission)
                    VALUES ('permanent_sync', 'REVOKE', run_source, role_row.rolname, function_row.schema_name, function_row.signature, 'EXECUTE');
                    INSERT INTO _out(action, username, detail) VALUES ('REVOKE', role_row.rolname, 'EXECUTE ON ' || function_row.signature);
                END LOOP;
            END LOOP;
        EXCEPTION
            WHEN SQLSTATE 'P0B01' THEN
                deferred_count := deferred_count + 1;
                cut_short := true;
            WHEN OTHERS THEN
                INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
                VALUES ('permanent_sync', 'ERROR', run_source, role_row.rolname, jsonb_build_object('op', 'privileges', 'sqlstate', SQLSTATE, 'sqlerrm', SQLERRM));
                INSERT INTO _out(action, username, detail) VALUES ('ERROR', role_row.rolname, 'privileges: ' || SQLERRM);
        END;
        CONTINUE WHEN cut_short;
        INSERT INTO ldap_reconcile.privilege_progress(username, reconciled_at) VALUES (role_row.rolname, clock_timestamp())
            ON CONFLICT ON CONSTRAINT privilege_progress_pkey DO UPDATE SET reconciled_at = EXCLUDED.reconciled_at;
    END LOOP;
    IF deferred_count > 0 THEN
        INSERT INTO _out(action, username, detail)
        VALUES ('DEFERRED', NULL, deferred_count || ' user(s) left for the next run: time budget ' || time_budget || ' reached');
    END IF;

    -- Group roles (PSQL_ALTER_GROUP_*): managed users in the mapped LDAP groups
    -- are members; managed users outside them are not. A role that does not
    -- exist is reported and skipped.
    FOR group_row IN SELECT DISTINCT c.object AS role_name FROM _config c WHERE c.kind = 'member' ORDER BY 1 LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = group_row.role_name) THEN
            INSERT INTO _out(action, username, detail) VALUES ('SKIP_GROUP', NULL, 'group role ' || group_row.role_name || ' does not exist');
            CONTINUE;
        END IF;
        FOR role_row IN
            SELECT a.rolname FROM pg_roles a
             WHERE EXISTS (SELECT 1 FROM pg_auth_members managed_by WHERE managed_by.member = a.oid AND managed_by.roleid = 'ldap_managed'::regrole) AND a.oid NOT IN (SELECT oid FROM _protected)
               AND a.rolname IN (SELECT m.username FROM _members m JOIN _config c ON c.ldap_group = m.ldap_group
                                  WHERE c.kind = 'member' AND c.object = group_row.role_name)
               AND a.rolname IN (SELECT tg.username FROM _target tg)
               AND NOT EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles gr ON gr.oid = am.roleid
                                WHERE am.member = a.oid AND gr.rolname = group_row.role_name)
             ORDER BY 1
        LOOP
            BEGIN
                EXECUTE format('GRANT %I TO %I', group_row.role_name, role_row.rolname);
                INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, permission)
                VALUES ('permanent_sync', 'GRANT', run_source, role_row.rolname, 'MEMBER OF ' || group_row.role_name);
                INSERT INTO _out(action, username, detail) VALUES ('GRANT', role_row.rolname, 'MEMBER OF ' || group_row.role_name);
            EXCEPTION WHEN OTHERS THEN
                INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
                VALUES ('permanent_sync', 'ERROR', run_source, role_row.rolname, jsonb_build_object('op', 'group grant', 'sqlstate', SQLSTATE, 'sqlerrm', SQLERRM));
                INSERT INTO _out(action, username, detail) VALUES ('ERROR', role_row.rolname, 'group grant: ' || SQLERRM);
            END;
        END LOOP;
        FOR role_row IN
            SELECT DISTINCT a.rolname FROM pg_roles a
              JOIN pg_auth_members am ON am.member = a.oid JOIN pg_roles gr ON gr.oid = am.roleid AND gr.rolname = group_row.role_name
             WHERE EXISTS (SELECT 1 FROM pg_auth_members managed_by WHERE managed_by.member = a.oid AND managed_by.roleid = 'ldap_managed'::regrole) AND a.oid NOT IN (SELECT oid FROM _protected)
               AND a.rolname NOT IN (SELECT m.username FROM _members m JOIN _config c ON c.ldap_group = m.ldap_group
                                      JOIN _target tg ON tg.username = m.username
                                      WHERE c.kind = 'member' AND c.object = group_row.role_name)
             ORDER BY 1
        LOOP
            BEGIN
                -- From 16 on a membership is one row per grantor, and a plain REVOKE only
                -- removes the bootstrap superuser's: each grantor's is revoked by name.
                IF current_setting('server_version_num')::INT >= 160000 THEN
                    FOR grant_row IN SELECT DISTINCT am.grantor::regrole::TEXT AS grantor_name FROM pg_auth_members am
                                      WHERE am.member = (SELECT oid FROM pg_roles WHERE rolname = role_row.rolname) AND am.roleid = (SELECT oid FROM pg_roles WHERE rolname = group_row.role_name) LOOP
                        EXECUTE format('REVOKE %I FROM %I GRANTED BY %s', group_row.role_name, role_row.rolname, grant_row.grantor_name);
                    END LOOP;
                ELSE
                    EXECUTE format('REVOKE %I FROM %I', group_row.role_name, role_row.rolname);
                END IF;
                IF EXISTS (SELECT 1 FROM pg_auth_members am WHERE am.member = (SELECT oid FROM pg_roles WHERE rolname = role_row.rolname) AND am.roleid = (SELECT oid FROM pg_roles WHERE rolname = group_row.role_name)) THEN
                    RAISE EXCEPTION 'membership of % in % is still held after the revoke', role_row.rolname, group_row.role_name;
                END IF;
                INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, permission)
                VALUES ('permanent_sync', 'REVOKE', run_source, role_row.rolname, 'MEMBER OF ' || group_row.role_name);
                INSERT INTO _out(action, username, detail) VALUES ('REVOKE', role_row.rolname, 'MEMBER OF ' || group_row.role_name);
            EXCEPTION WHEN OTHERS THEN
                INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
                VALUES ('permanent_sync', 'ERROR', run_source, role_row.rolname, jsonb_build_object('op', 'group revoke', 'sqlstate', SQLSTATE, 'sqlerrm', SQLERRM));
                INSERT INTO _out(action, username, detail) VALUES ('ERROR', role_row.rolname, 'group revoke: ' || SQLERRM);
            END;
        END LOOP;
    END LOOP;

    -- Configured schemas that do not exist (yet): nothing to grant there.
    FOR group_row IN SELECT DISTINCT c.object FROM _config c WHERE c.kind IN ('read','write')
              AND NOT EXISTS (SELECT 1 FROM pg_namespace n WHERE n.nspname = c.object) ORDER BY 1 LOOP
        INSERT INTO _out(action, username, detail) VALUES ('SKIP_SCHEMA', NULL, 'schema ' || group_row.object || ' does not exist');
    END LOOP;
    RETURN QUERY SELECT o.action, o.username, o.detail FROM _out o ORDER BY o.ord;
    RETURN;
END;
$$;

-- Only the role that installs it (the admin) runs it.
REVOKE ALL ON FUNCTION ldap_reconcile.reconcile_permissions(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[]) FROM PUBLIC;

-- No copy may remain in public, whoever put it there.
DROP FUNCTION IF EXISTS public.reconcile_permissions(TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[]);
DROP FUNCTION IF EXISTS public.reconcile_permissions(TEXT[], TEXT, TEXT);
