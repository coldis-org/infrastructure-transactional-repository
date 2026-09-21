-- USER lifecycle reconcile (v0).
--
-- Receives a target list (resolved from LDAP by the wrapper). Creates users
-- present in the target but missing from the catalog; drops users that the
-- reconcile previously created and are no longer in the target. GROUP roles,
-- GRANTs and membership are out of scope for this iteration.
--
-- Audit:
--   Inserts in permissions_audit only when an operation actually happens
--   (CREATE_USER / DROP_USER / ERROR). A no-op run writes nothing.
--
-- Ownership rule (DROP safety):
--   A role becomes a DROP candidate only if permissions_audit has a
--   CREATE_USER row for it. This protects roles created by other paths
--   (psql_configure.sh, manual ops, system roles) — they're never owned
--   by this function, so they're never dropped.
--
-- Defense in depth on top of the ownership rule, the catalog scan excludes:
--   rolsuper, rolreplication, rolbypassrls, the postgres role itself.

CREATE OR REPLACE FUNCTION reconcile_permissions(
    p_target_users   TEXT[],
    p_source         TEXT DEFAULT 'reconcile',
    -- Role that inherits ownership of objects orphaned by DROP USER (via
    -- REASSIGN OWNED). Usually the application user (POSTGRES_DEFAULT_USER).
    -- NULL falls back to CURRENT_USER (the function owner under SECURITY
    -- DEFINER — typically postgres), which is the historical behavior.
    p_owner_fallback TEXT DEFAULT NULL
)
RETURNS TABLE(action TEXT, username TEXT) AS $$
DECLARE
    v_lock_acquired    BOOLEAN := FALSE;
    -- Permissive regex: accepts nome.sobrenome, dept.team.role, simple
    -- service accounts. Real defense comes from the role-attribute filters.
    v_user_regex       TEXT    := '^[a-z][a-z0-9_.-]*$';
    v_existing_users   TEXT[];
    v_to_create        TEXT[];
    v_to_drop          TEXT[];
    v_username         TEXT;
    v_reassigned_count INT;
    v_target_owner     TEXT;
BEGIN
    PERFORM pg_advisory_lock(hashtext('reconcile_permissions'));
    v_lock_acquired := TRUE;

    -- Resolve REASSIGN OWNED target. Validate role exists to fail clearly
    -- instead of bombing inside the EXECUTE.
    v_target_owner := COALESCE(p_owner_fallback, CURRENT_USER::TEXT);
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_target_owner) THEN
        RAISE EXCEPTION 'reconcile_permissions: p_owner_fallback role % does not exist', v_target_owner;
    END IF;

    BEGIN
        -- Catalog roles previously created by this function (ownership check).
        SELECT COALESCE(array_agg(pr.rolname), ARRAY[]::TEXT[])
          INTO v_existing_users
          FROM pg_roles pr
         WHERE pr.rolname ~ v_user_regex
           AND pr.rolcanlogin    = TRUE
           AND pr.rolsuper       = FALSE
           AND pr.rolreplication = FALSE
           AND pr.rolbypassrls   = FALSE
           AND pr.rolname <> 'postgres'
           AND EXISTS (
               SELECT 1 FROM permissions_audit a
                WHERE a.flow    = 'permanent_sync'
                  AND a.action  = 'CREATE_USER'
                  AND a.grantee = pr.rolname
           );

        -- Target users not yet in catalog. Regex filter discards adversarial
        -- entries silently rather than aborting the whole run.
        SELECT COALESCE(array_agg(u), ARRAY[]::TEXT[])
          INTO v_to_create
          FROM unnest(COALESCE(p_target_users, ARRAY[]::TEXT[])) AS u
         WHERE u ~ v_user_regex
           AND NOT (u = ANY(v_existing_users));

        -- Owned roles no longer in target.
        SELECT COALESCE(array_agg(u), ARRAY[]::TEXT[])
          INTO v_to_drop
          FROM unnest(v_existing_users) AS u
         WHERE NOT (u = ANY(COALESCE(p_target_users, ARRAY[]::TEXT[])));

        FOREACH v_username IN ARRAY v_to_create
        LOOP
            BEGIN
                IF v_username !~ v_user_regex THEN
                    RAISE EXCEPTION 'username % does not match regex (defense check)', v_username;
                END IF;

                EXECUTE format(
                    'CREATE USER %I WITH NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN',
                    v_username
                );

                INSERT INTO permissions_audit(flow, action, source, grantee, detail)
                VALUES ('permanent_sync', 'CREATE_USER', p_source, v_username,
                        jsonb_build_object('reason', 'present in target, absent in catalog'));

                action := 'CREATE_USER'; username := v_username; RETURN NEXT;

            EXCEPTION WHEN OTHERS THEN
                INSERT INTO permissions_audit(flow, action, source, grantee, detail)
                VALUES ('permanent_sync', 'ERROR', p_source, v_username,
                        jsonb_build_object('op', 'CREATE_USER',
                                           'sqlstate', SQLSTATE,
                                           'sqlerrm', SQLERRM));
                action := 'ERROR'; username := v_username; RETURN NEXT;
            END;
        END LOOP;

        FOREACH v_username IN ARRAY v_to_drop
        LOOP
            BEGIN
                IF v_username !~ v_user_regex THEN
                    RAISE EXCEPTION 'username % does not match regex (defense check)', v_username;
                END IF;

                -- Count objects owned by the user before REASSIGN. Anything
                -- > 0 means objects were transferred to the function owner
                -- (CURRENT_USER under SECURITY DEFINER) and will need manual
                -- cleanup or re-ownership.
                SELECT COUNT(*)
                  INTO v_reassigned_count
                  FROM pg_shdepend sd
                  JOIN pg_authid a ON a.oid = sd.refobjid
                 WHERE a.rolname = v_username
                   AND sd.deptype = 'o';

                EXECUTE format('REASSIGN OWNED BY %I TO %I', v_username, v_target_owner);
                EXECUTE format('DROP OWNED BY %I', v_username);
                EXECUTE format('DROP USER %I', v_username);

                INSERT INTO permissions_audit(flow, action, source, grantee, detail)
                VALUES ('permanent_sync', 'DROP_USER', p_source, v_username,
                        jsonb_build_object(
                            'reason', 'absent from target, present in catalog',
                            'reassigned_objects', v_reassigned_count,
                            'reassigned_to', v_target_owner
                        ));

                action := 'DROP_USER'; username := v_username; RETURN NEXT;

            EXCEPTION WHEN OTHERS THEN
                INSERT INTO permissions_audit(flow, action, source, grantee, detail)
                VALUES ('permanent_sync', 'ERROR', p_source, v_username,
                        jsonb_build_object('op', 'DROP_USER',
                                           'sqlstate', SQLSTATE,
                                           'sqlerrm', SQLERRM));
                action := 'ERROR'; username := v_username; RETURN NEXT;
            END;
        END LOOP;

    EXCEPTION WHEN OTHERS THEN
        -- No audit INSERT here: RAISE rolls back the outer transaction,
        -- which would discard the insert anyway. Use NOTICE so the caller's
        -- log captures the failure.
        RAISE NOTICE 'reconcile_permissions failed: SQLSTATE=% SQLERRM=%', SQLSTATE, SQLERRM;

        IF v_lock_acquired THEN
            PERFORM pg_advisory_unlock(hashtext('reconcile_permissions'));
            v_lock_acquired := FALSE;
        END IF;

        RAISE;
    END;

    IF v_lock_acquired THEN
        PERFORM pg_advisory_unlock(hashtext('reconcile_permissions'));
    END IF;

    RETURN;
END;
$$ LANGUAGE plpgsql
   SECURITY DEFINER
   SET search_path = pg_catalog, public;

-- Lock down EXECUTE: SECURITY DEFINER + default PUBLIC EXECUTE means any
-- login user could trigger CREATE/DROP USER. Restrict to the admin role
-- (passed by the installer via psql -v admin_user=...).
REVOKE ALL ON FUNCTION reconcile_permissions(TEXT[], TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reconcile_permissions(TEXT[], TEXT, TEXT) TO :"admin_user";
