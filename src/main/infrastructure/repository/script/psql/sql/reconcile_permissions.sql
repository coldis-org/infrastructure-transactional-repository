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
    valid_name_pattern     CONSTANT TEXT := '^[a-z_][a-z0-9_.-]*$';
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
    access_level       TEXT;
    read_tables      TEXT[];
    is_first_run   BOOLEAN;
    is_in_ldap   BOOLEAN;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('reconcile_permissions'));
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
           OR (config_row.kind <> 'read' AND config_row.tbl IS NOT NULL)
           OR (config_row.kind IN ('read', 'write') AND (config_row.object IN ('ldap_reconcile', 'information_schema')
                                                       OR config_row.object LIKE 'pg\_%')) THEN
            RAISE EXCEPTION 'reconcile_permissions: invalid configuration row (%, %, %, %)', config_row.kind, config_row.object, config_row.tbl, config_row.ldap_group;
        END IF;
    END LOOP;
    FOR member_row IN SELECT * FROM _members LOOP
        IF member_row.username !~ valid_name_pattern OR NOT EXISTS (SELECT 1 FROM _config c WHERE c.ldap_group = member_row.ldap_group) THEN
            RAISE EXCEPTION 'reconcile_permissions: invalid member row (%, %)', member_row.ldap_group, member_row.username;
        END IF;
    END LOOP;

    -- Desired state: per user and configured schema, the level (write > read)
    -- and, for read, the tables (NULL = every table).
    CREATE TEMP TABLE _target ON COMMIT DROP AS SELECT DISTINCT m.username FROM _members m;
    CREATE TEMP TABLE _wanted ON COMMIT DROP AS
        SELECT m.username, c.object AS schema_name,
               CASE WHEN bool_or(c.kind = 'write') THEN 'write' ELSE 'read' END AS level,
               CASE WHEN bool_or(c.kind = 'write') OR bool_or(c.tbl IS NULL) THEN NULL
                    ELSE array_agg(DISTINCT c.tbl) END AS tables
          FROM _config c JOIN _members m ON m.ldap_group = c.ldap_group
         WHERE c.kind IN ('read', 'write')
         GROUP BY m.username, c.object;
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
                OR EXISTS (SELECT 1 FROM pg_roles privileged
                            WHERE privileged.oid <> a.oid
                              AND (privileged.rolsuper OR privileged.rolcreaterole OR privileged.rolcreatedb
                                   OR privileged.rolreplication OR privileged.rolbypassrls OR privileged.rolname LIKE 'pg\_%')
                              AND pg_has_role(a.oid, privileged.oid, 'MEMBER')))
    LOOP
        RAISE EXCEPTION 'reconcile_permissions: group role % is privileged or a login role; refusing to manage its membership', group_row.role_name;
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
        IF drops_allowed THEN
            BEGIN
                EXECUTE format('REASSIGN OWNED BY %I TO %I', role_row.rolname, owner_role);
                EXECUTE format('DROP OWNED BY %I', role_row.rolname);
                EXECUTE format('DROP ROLE %I', role_row.rolname);
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
    FOR role_row IN
        SELECT a.rolname, a.oid FROM pg_roles a
         WHERE EXISTS (SELECT 1 FROM pg_auth_members managed_by WHERE managed_by.member = a.oid AND managed_by.roleid = 'ldap_managed'::regrole) AND a.rolname <> 'ldap_managed'
           AND a.oid NOT IN (SELECT oid FROM _protected)
         ORDER BY a.rolname
    LOOP
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
                EXECUTE format('REVOKE %s ON DATABASE %I FROM %I', privilege, database_name, role_row.rolname);
                INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, permission, detail)
                VALUES ('permanent_sync', 'REVOKE', run_source, role_row.rolname, privilege, jsonb_build_object('database', database_name));
                INSERT INTO _out(action, username, detail) VALUES ('REVOKE', role_row.rolname, privilege || ' ON DATABASE ' || database_name);
            END LOOP;

            -- Each configured schema that exists.
            FOR schema_row IN SELECT sc.schema_name, sc.schema_oid FROM _schemas sc ORDER BY 1 LOOP
                SELECT w.level, w.tables INTO access_level, read_tables
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
                    EXECUTE format('REVOKE %s ON SCHEMA %I FROM %I', privilege, schema_row.schema_name, role_row.rolname);
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
                    IF relation_row.relkind = 'S' THEN
                        desired_privileges := CASE access_level WHEN 'write' THEN all_sequence_privileges WHEN 'read' THEN ARRAY['SELECT'] ELSE ARRAY[]::TEXT[] END;
                    ELSE
                        desired_privileges := CASE
                            WHEN access_level = 'write' THEN all_table_privileges
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
                        EXECUTE format('REVOKE %s ON %s %I.%I FROM %I', privilege, CASE WHEN relation_row.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END,
                                       relation_row.schema_name, relation_row.relname, role_row.rolname);
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
                    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM %I', function_row.signature, role_row.rolname);
                    INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, schema_name, table_name, permission)
                    VALUES ('permanent_sync', 'REVOKE', run_source, role_row.rolname, function_row.schema_name, function_row.signature, 'EXECUTE');
                    INSERT INTO _out(action, username, detail) VALUES ('REVOKE', role_row.rolname, 'EXECUTE ON ' || function_row.signature);
                END LOOP;
            END LOOP;
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO ldap_reconcile.permissions_audit(flow, action, source, grantee, detail)
            VALUES ('permanent_sync', 'ERROR', run_source, role_row.rolname, jsonb_build_object('op', 'privileges', 'sqlstate', SQLSTATE, 'sqlerrm', SQLERRM));
            INSERT INTO _out(action, username, detail) VALUES ('ERROR', role_row.rolname, 'privileges: ' || SQLERRM);
        END;
    END LOOP;

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
            SELECT a.rolname FROM pg_roles a
              JOIN pg_auth_members am ON am.member = a.oid JOIN pg_roles gr ON gr.oid = am.roleid AND gr.rolname = group_row.role_name
             WHERE EXISTS (SELECT 1 FROM pg_auth_members managed_by WHERE managed_by.member = a.oid AND managed_by.roleid = 'ldap_managed'::regrole) AND a.oid NOT IN (SELECT oid FROM _protected)
               AND a.rolname NOT IN (SELECT m.username FROM _members m JOIN _config c ON c.ldap_group = m.ldap_group
                                      WHERE c.kind = 'member' AND c.object = group_row.role_name)
             ORDER BY 1
        LOOP
            BEGIN
                EXECUTE format('REVOKE %I FROM %I', group_row.role_name, role_row.rolname);
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
