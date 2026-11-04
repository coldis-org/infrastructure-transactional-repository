#!/bin/bash

# Tests for the LDAP permissions reconcile (psql_reconcile_permissions.sh and
# sql/reconcile_permissions.sql). They run on the host and drive a container of
# the repository image and an OpenLDAP container on a private network: users and
# privileges follow LDAP, legacy users are adopted, empty groups are valid, and
# every failure (LDAP down, bad bind, missing group, untrusted name, a database
# error mid-run) leaves the database exactly as it was.
#
#   docker build -t repository-test -f src/main/infrastructure/repository/Dockerfile7 \
#     src/main/infrastructure/repository
#   bash src/test/infrastructure/repository/reconcile_test.sh repository-test
#
# LDAP_IMAGE overrides the directory image (default osixia/openldap:1.5.0).
# Needs docker; creates and removes its containers, volume and network.
# Exits non-zero when any test fails.

IMAGE=${1:?usage: reconcile_test.sh <image>}
LDAP_IMAGE=${LDAP_IMAGE:-osixia/openldap:1.5.0}
PREFIX=reconcile-test-$$
NET=$PREFIX-net; DB=$PREFIX-db; LDAP=$PREFIX-ldap
BASE="dc=test,dc=org"; GROUPS_DN="ou=groups,$BASE"; ADMIN_DN="cn=admin,$BASE"
pass=0; fail=0

ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
cleanup() {
	docker rm -f "$DB" "$LDAP" >/dev/null 2>&1
	docker volume rm -f "$PREFIX-vol" >/dev/null 2>&1
	# shellcheck disable=SC2034  # iteration only counts the retries
	for iteration in 1 2 3 4 5; do docker network inspect "$NET" >/dev/null 2>&1 || break; docker network rm "$NET" >/dev/null 2>&1 && break; sleep 1; done
}
trap cleanup EXIT

sql() { docker exec "$DB" psql -X -q -tA -U postgres -d appdb -c "$1" 2>&1; }
ldap() { docker exec -i "$LDAP" ldapmodify -x -H ldap://localhost -D "$ADMIN_DN" -w admin >/dev/null 2>&1; }
members() { # group user... : replaces the group's members (none = empty group)
	local group=$1; shift
	{ printf 'dn: cn=%s,%s\nchangetype: modify\nreplace: memberUid\n' "$group" "$GROUPS_DN"; for member_name in "$@"; do printf 'memberUid: %s\n' "$member_name"; done; } | ldap
}
config() { # lines for /local/application.env (sourced by the wrapper every run)
	docker exec -i "$DB" sh -c 'mkdir -p /local && cat > /local/application.env' <<<"$1"
}
reconcile() { OUT=$(docker exec "$DB" sh -c 'cd /opt/psql-script && RECONCILE_SOURCE=manual ./psql_reconcile_permissions.sh' 2>&1); RC=$?; }
exists() { [ "$(sql "SELECT count(*) FROM pg_roles WHERE rolname = '$1'")" = 1 ]; }
managed() { [ "$(sql "SELECT count(*) FROM pg_auth_members WHERE member = '$1'::regrole AND roleid = 'ldap_managed'::regrole")" = 1 ]; }
can() { [ "$(sql "SELECT has_table_privilege('$1', '$2', '$3')")" = t ]; }
# Everything a reconcile may change: roles, memberships, and the ACLs of the database and of
# every object in the test schemas.
snapshot() {
	sql "SELECT 'role ' || rolname || ' ' || rolcanlogin FROM pg_roles WHERE rolname !~ '^pg_' UNION ALL
	     SELECT 'member ' || m.rolname || ' ' || g.rolname FROM pg_auth_members a JOIN pg_roles m ON m.oid = a.member JOIN pg_roles g ON g.oid = a.roleid WHERE g.rolname !~ '^pg_' UNION ALL
	     SELECT 'db ' || coalesce(datacl::text, '') FROM pg_database WHERE datname = 'appdb' UNION ALL
	     SELECT 'schema ' || nspname || ' ' || coalesce(nspacl::text, '') FROM pg_namespace WHERE nspname ~ '^s[0-9]' UNION ALL
	     SELECT 'rel ' || c.oid::regclass || ' ' || coalesce(relacl::text, '') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE nspname ~ '^s[0-9]' UNION ALL
	     SELECT 'fn ' || p.oid::regprocedure || ' ' || coalesce(proacl::text, '') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE nspname ~ '^s[0-9]'
	     ORDER BY 1"
}
BASE_CONFIG='PSQL_READ_SCHEMA_S1=readers
PSQL_READ_SCHEMA_S2_TABLE_T1=temp
PSQL_WRITE_SCHEMA_S3=writers'

cleanup
docker network create "$NET" >/dev/null || exit 2
echo "== $IMAGE with $LDAP_IMAGE"

# Directory: three groups, one of them empty (temporary permissions).
docker run -d --name "$LDAP" --network "$NET" -e LDAP_ORGANISATION=test -e LDAP_DOMAIN=test.org -e LDAP_ADMIN_PASSWORD=admin "$LDAP_IMAGE" >/dev/null || exit 2
# shellcheck disable=SC2034  # iteration only counts the retries
for iteration in $(seq 60); do docker exec "$LDAP" ldapsearch -x -H ldap://localhost -D "$ADMIN_DN" -w admin -b "$BASE" -s base dn >/dev/null 2>&1 && break; sleep 2; done
docker exec -i "$LDAP" ldapadd -x -H ldap://localhost -D "$ADMIN_DN" -w admin >/dev/null <<EOF || { echo "cannot seed LDAP"; exit 2; }
dn: $GROUPS_DN
objectClass: organizationalUnit
ou: groups

dn: cn=readers,$GROUPS_DN
objectClass: posixGroup
cn: readers
gidNumber: 5001
memberUid: alice
memberUid: bob
memberUid: erin

dn: cn=writers,$GROUPS_DN
objectClass: posixGroup
cn: writers
gidNumber: 5002
memberUid: carol

dn: cn=temp,$GROUPS_DN
objectClass: posixGroup
cn: temp
gidNumber: 5003

dn: cn=staff,$GROUPS_DN
objectClass: posixGroup
cn: staff
cn: staff-team
gidNumber: 5004
memberUid: alice
memberUid: henry

dn: cn=gon,$GROUPS_DN
objectClass: groupOfNames
cn: gon
member: cn=admin,$BASE
EOF

# Database, with LDAP but no PSQL_* configuration in its environment.
docker run -d --name "$DB" --network "$NET" -v "$PREFIX-vol:/var/lib/postgresql" \
	-e POSTGRES_DEFAULT_USER=app -e POSTGRES_DEFAULT_PASSWORD=app -e POSTGRES_DEFAULT_DATABASE=appdb \
	-e LDAP_HOST="$LDAP:389" -e LDAP_USER="$ADMIN_DN" -e LDAP_PASSWORD=admin -e LDAP_GROUPS="$GROUPS_DN" \
	"$IMAGE" >/dev/null || exit 2
# shellcheck disable=SC2034  # iteration only counts the retries
for iteration in $(seq 120); do docker logs "$DB" 2>&1 | grep -q "Database started and configured" && break; sleep 1; done
LOGS=$(docker logs "$DB" 2>&1)
if grep -q "Database started and configured" <<<"$LOGS"; then ok "boot: the database is configured"; else bad "boot: the database is configured"; fi
if grep -q "nothing to reconcile" <<<"$LOGS" && ! exists alice; then ok "boot: with no PSQL_* configuration the reconcile does nothing"; else bad "boot: with no PSQL_* configuration the reconcile does nothing"; fi

# Schemas owned by the application user, and users from the old scripts.
sql "SET ROLE app;
     CREATE SCHEMA s1; CREATE TABLE s1.t_a(i int); CREATE TABLE s1.t_b(i int); CREATE SEQUENCE s1.q;
     CREATE FUNCTION s1.f() RETURNS int LANGUAGE sql AS 'SELECT 1';
     CREATE SCHEMA s2; CREATE TABLE s2.t1(i int); CREATE TABLE s2.t2(i int);
     CREATE SCHEMA s3; CREATE TABLE s3.w1(i int); RESET ROLE;
     CREATE ROLE dave LOGIN; GRANT USAGE ON SCHEMA s1 TO dave; GRANT SELECT ON ALL TABLES IN SCHEMA s1 TO dave;
     CREATE ROLE erin LOGIN; GRANT USAGE ON SCHEMA s1 TO erin; GRANT SELECT ON ALL TABLES IN SCHEMA s1 TO erin;
     CREATE ROLE svc LOGIN; GRANT USAGE ON SCHEMA s3 TO svc; GRANT SELECT ON s3.w1 TO svc;
     CREATE ROLE handmade LOGIN;
     CREATE ROLE bi LOGIN; GRANT USAGE ON SCHEMA s2 TO bi; GRANT SELECT ON s2.t2 TO bi;" >/dev/null
config "$BASE_CONFIG"

# First run.
reconcile
if [ $RC = 0 ]; then ok "first run succeeds"; else bad "first run succeeds"; fi
if exists alice && exists bob && exists carol && managed alice && managed carol; then ok "alice and bob (readers) and carol (writers) are created"; else bad "alice and bob (readers) and carol (writers) are created"; fi
if managed erin && grep -q "ADOPT_USER erin" <<<"$OUT" && ! grep -q "CREATE_USER erin" <<<"$OUT"; then ok "erin, from the old scripts and in LDAP, is adopted, not recreated"; else bad "erin, from the old scripts and in LDAP, is adopted, not recreated"; fi
if ! exists dave && grep -q "DROP_USER dave" <<<"$OUT"; then ok "dave, from the old scripts and no longer in LDAP, is adopted and dropped"; else bad "dave, from the old scripts and no longer in LDAP, is adopted and dropped"; fi
if exists svc && ! managed svc && exists handmade && ! managed handmade && can svc s3.w1 SELECT && exists app && exists bi && ! managed bi && can bi s2.t2 SELECT; then ok "unmanaged roles are untouched (svc on a write schema, bi on a table-scoped read schema, handmade, app)"; else bad "unmanaged roles are untouched (svc on a write schema, bi on a table-scoped read schema, handmade, app)"; fi
if can alice s1.t_a SELECT && can alice s1.t_b SELECT && ! can alice s1.t_a INSERT; then ok "readers read every table of s1 and write none"; else bad "readers read every table of s1 and write none"; fi
if ! can alice s2.t1 SELECT && ! can alice s3.w1 SELECT; then ok "readers have no access to s2 or s3"; else bad "readers have no access to s2 or s3"; fi
if can carol s3.w1 INSERT && can carol s3.w1 DELETE; then ok "writers write s3"; else bad "writers write s3"; fi
if ! can bob s2.t1 SELECT; then ok "an empty group (temp) grants nothing"; else bad "an empty group (temp) grants nothing"; fi
if [ "$(sql "SELECT count(*) > 0 FROM ldap_reconcile.permissions_audit WHERE action = 'CREATE_USER'")" = t ]; then ok "changes are recorded in permissions_audit"; else bad "changes are recorded in permissions_audit"; fi

reconcile
if [ $RC = 0 ] && grep -q "no changes" <<<"$OUT"; then ok "a second run changes nothing"; else bad "a second run changes nothing"; fi

sql "SET ROLE app; CREATE TABLE s1.t_c(i int); RESET ROLE;" >/dev/null
reconcile
if [ $RC = 0 ] && can alice s1.t_c SELECT; then ok "a new table is granted on the next run"; else bad "a new table is granted on the next run"; fi

members temp frank; reconcile
if exists frank && can frank s2.t1 SELECT && ! can frank s2.t2 SELECT && ! can frank s1.t_a SELECT; then ok "a member added to an empty group gets exactly that table"; else bad "a member added to an empty group gets exactly that table"; fi

members writers; members readers alice bob erin carol; reconcile
if [ $RC = 0 ] && ! can carol s3.w1 INSERT && ! can carol s3.w1 SELECT && can carol s1.t_a SELECT; then ok "a writer moved to readers loses write on s3 and reads s1"; else bad "a writer moved to readers loses write on s3 and reads s1"; fi

# A user's objects survive the user.
sql "CREATE TABLE s1.bob_t(i int); INSERT INTO s1.bob_t SELECT generate_series(1, 42); ALTER TABLE s1.bob_t OWNER TO bob;
     CREATE FUNCTION s1.bob_f() RETURNS int LANGUAGE sql SECURITY DEFINER AS 'SELECT 1'; ALTER FUNCTION s1.bob_f() OWNER TO bob;
     CREATE VIEW s1.bob_v AS SELECT * FROM s1.t_a; ALTER VIEW s1.bob_v OWNER TO bob; GRANT SELECT ON s1.bob_v TO PUBLIC;" >/dev/null
members readers alice erin carol; reconcile
if [ "$(sql "SELECT prosecdef FROM pg_proc WHERE proname = 'bob_f'")" = f ] && grep -q "SECURITY_INVOKER bob s1.bob_f()" <<<"$OUT" && [ "$(sql "SELECT has_table_privilege('public', 's1.bob_v', 'SELECT')")" = f ] && grep -q "REVOKE_VIEW_GRANTS bob s1.bob_v" <<<"$OUT"; then ok "a dropped user's SECURITY DEFINER function becomes SECURITY INVOKER and their view loses its grants before the reassign"; else bad "a dropped user's SECURITY DEFINER function becomes SECURITY INVOKER and their view loses its grants before the reassign"; fi
if [ $RC = 0 ] && ! exists bob; then ok "a user removed from LDAP is dropped"; else bad "a user removed from LDAP is dropped"; fi
if [ "$(sql "SELECT count(*) || ' '|| tableowner FROM s1.bob_t, pg_tables WHERE tablename = 'bob_t' GROUP BY tableowner")" = "42 app" ]; then ok "their table survives, with its data, owned by the application user"; else bad "their table survives, with its data, owned by the application user"; fi

# The reconcile lives in its own schema, owned by the admin and closed to the application.
if [ "$(sql "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname = 'reconcile_permissions' AND n.nspname = 'ldap_reconcile' AND pg_get_userbyid(p.proowner) = 'postgres'")" = 1 ] \
	&& [ "$(sql "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname = 'reconcile_permissions' AND n.nspname = 'public'")" = 0 ]; then ok "the function is the admin's, in ldap_reconcile, and none is in public"; else bad "the function is the admin's, in ldap_reconcile, and none is in public"; fi
APP_DROP=$(docker exec "$DB" sh -c "PGPASSWORD=app psql -X -tA -h 127.0.0.1 -U app -d appdb -c 'DROP FUNCTION ldap_reconcile.reconcile_permissions(text, text, text, text, boolean, text[])'" 2>&1)
APP_CREATE=$(docker exec "$DB" sh -c "PGPASSWORD=app psql -X -tA -h 127.0.0.1 -U app -d appdb -c 'CREATE TABLE ldap_reconcile.x(i int)'" 2>&1)
if [ "$(sql "SELECT count(*) FROM pg_proc WHERE proname = 'reconcile_permissions'")" = 1 ] && grep -qiE "denied|negad" <<<"$APP_DROP" && grep -qiE "denied|negad" <<<"$APP_CREATE"; then ok "the application user can neither drop the function nor create in its schema"; else bad "the application user can neither drop the function nor create in its schema"; fi

# After the first run, a role granted access by other means is never taken over.
sql "CREATE ROLE svc2 LOGIN; GRANT USAGE ON SCHEMA s1 TO svc2; GRANT SELECT ON s1.t_a TO svc2;" >/dev/null
reconcile
if [ $RC = 0 ] && exists svc2 && ! managed svc2 && can svc2 s1.t_a SELECT; then ok "a role granted a read schema after the first run is left alone"; else bad "a role granted a read schema after the first run is left alone"; fi

# A role granted a managed user's role is not managed through it.
sql "CREATE ROLE svc3 LOGIN; GRANT alice TO svc3; GRANT USAGE ON SCHEMA s1 TO svc3; GRANT SELECT ON s1.t_a TO svc3;" >/dev/null
reconcile
if [ $RC = 0 ] && exists svc3 && ! managed svc3 && [ "$(sql "SELECT has_table_privilege('svc3', 's1.t_a', 'SELECT WITH GRANT OPTION') OR has_table_privilege('svc3', 's1.t_a', 'SELECT')")" = t ] && ! grep -q "svc3" <<<"$OUT"; then ok "a role granted a managed user's role is left alone"; else bad "a role granted a managed user's role is left alone"; fi

# A privilege granted by a role other than the owner is revoked too, and stays revoked.
sql "CREATE ROLE delegator NOLOGIN; GRANT USAGE ON SCHEMA s3 TO delegator; GRANT SELECT ON s3.w1 TO delegator WITH GRANT OPTION;
     SET ROLE delegator; GRANT SELECT ON s3.w1 TO alice; RESET ROLE;" >/dev/null
reconcile
FIRST=$OUT
reconcile
if [ $RC = 0 ] && ! can alice s3.w1 SELECT && grep -q "REVOKE alice SELECT ON s3.w1" <<<"$FIRST" && ! grep -q "s3.w1" <<<"$OUT"; then ok "a grant from a third role is revoked once and does not come back as a change"; else bad "a grant from a third role is revoked once and does not come back as a change"; fi

# Group names compare without case, and an entry with several cn values is found by any of them.
config "PSQL_READ_SCHEMA_S1=Readers,Staff-Team
PSQL_READ_SCHEMA_S2_TABLE_T1=temp
PSQL_WRITE_SCHEMA_S3=WRITERS"
reconcile
if [ $RC = 0 ] && can alice s1.t_a SELECT && can henry s1.t_a SELECT && exists carol; then ok "group names match without case, and a second cn value names the group"; else bad "group names match without case, and a second cn value names the group"; fi
config "$BASE_CONFIG"
reconcile

# Write on one table: ALL on it, USAGE on the schema, nothing on the other tables.
config "$BASE_CONFIG
PSQL_WRITE_SCHEMA_S2_TABLE_T2=readers"
reconcile
if [ $RC = 0 ] && can alice s2.t2 INSERT && can alice s2.t2 SELECT && ! can alice s2.t1 SELECT && [ "$(sql "SELECT has_schema_privilege('alice', 's2', 'USAGE') AND NOT has_schema_privilege('alice', 's2', 'CREATE')")" = t ]; then ok "a single-table write mapping grants ALL on that table and USAGE on the schema only"; else bad "a single-table write mapping grants ALL on that table and USAGE on the schema only"; fi
config "$BASE_CONFIG"
reconcile
if [ $RC = 0 ] && ! can alice s2.t2 INSERT && ! can alice s2.t2 SELECT; then ok "and removing the mapping revokes it"; else bad "and removing the mapping revokes it"; fi

# A time budget commits part of the work; the users left go first next run.
sql "REVOKE SELECT ON s1.t_a FROM alice; REVOKE SELECT ON s1.t_a FROM erin;" >/dev/null
config "$BASE_CONFIG
RECONCILE_TIME_BUDGET=0"
reconcile
if [ $RC = 3 ] && grep -q "DEFERRED" <<<"$OUT" && [ "$(grep -cE "GRANT (alice|erin) SELECT ON s1.t_a" <<<"$OUT")" -le 1 ]; then ok "with the time budget spent, one user is done and the rest deferred (exit 3)"; else bad "with the time budget spent, one user is done and the rest deferred (exit 3)"; fi
# shellcheck disable=SC2034  # iteration only counts the runs
for iteration in 1 2 3 4 5 6 7 8 9 10; do reconcile; done
if can alice s1.t_a SELECT && can erin s1.t_a SELECT; then ok "successive budgeted runs reach every user (least recently reconciled first)"; else bad "successive budgeted runs reach every user (least recently reconciled first)"; fi
config "$BASE_CONFIG"
reconcile
if [ $RC = 0 ] && ! grep -q "DEFERRED" <<<"$OUT" && grep -qE "done: .* in [0-9]+s" <<<"$OUT"; then ok "without the budget reached the run completes, and logs its duration"; else bad "without the budget reached the run completes, and logs its duration"; fi

# Sequences and functions follow the schema level.
if [ "$(sql "SELECT has_sequence_privilege('alice', 's1.q', 'SELECT') AND NOT has_sequence_privilege('alice', 's1.q', 'UPDATE') AND has_function_privilege('alice', 's1.f()', 'EXECUTE')")" = t ]; then ok "readers get SELECT on the schema's sequences and EXECUTE on its functions"; else bad "readers get SELECT on the schema's sequences and EXECUTE on its functions"; fi

# Group roles (PSQL_ALTER_GROUP_*), when enabled.
sql "CREATE ROLE grp NOLOGIN" >/dev/null
config "$BASE_CONFIG
PSQL_ALTER_GROUP_GRP=readers
SKIP_ALTER_GROUP=false"
reconcile
if [ $RC = 0 ] && [ "$(sql "SELECT pg_has_role('alice', 'grp', 'MEMBER')")" = t ]; then ok "PSQL_ALTER_GROUP_GRP makes the group's managed users members of grp"; else bad "PSQL_ALTER_GROUP_GRP makes the group's managed users members of grp"; fi
config "$BASE_CONFIG"
reconcile
if [ $RC = 0 ] && [ "$(sql "SELECT pg_has_role('alice', 'grp', 'MEMBER')")" = t ]; then ok "with the mapping removed and SKIP_ALTER_GROUP back on, membership is left alone"; else bad "with the mapping removed and SKIP_ALTER_GROUP back on, membership is left alone"; fi
config "$BASE_CONFIG
PSQL_ALTER_GROUP_GRP=writers
SKIP_ALTER_GROUP=false"
reconcile
if [ $RC = 0 ] && [ "$(sql "SELECT pg_has_role('alice', 'grp', 'MEMBER')")" = f ]; then ok "a user leaving the mapped LDAP group leaves grp"; else bad "a user leaving the mapped LDAP group leaves grp"; fi
config "$BASE_CONFIG
PSQL_ALTER_GROUP_GRP=staff
SKIP_ALTER_GROUP=false"
reconcile
if [ $RC = 0 ] && [ "$(sql "SELECT pg_has_role('alice', 'grp', 'MEMBER')")" = t ] && ! exists henry; then ok "an alter-group mapping adds users who have a permission, and creates no one (henry is only in it)"; else bad "an alter-group mapping adds users who have a permission, and creates no one (henry is only in it)"; fi
members readers alice erin carol jane.doe; reconcile
sql "CREATE ROLE grpadmin NOLOGIN; GRANT grp TO grpadmin WITH ADMIN OPTION; SET ROLE grpadmin; GRANT grp TO erin; GRANT grp TO \"jane.doe\"; RESET ROLE;" >/dev/null
reconcile
if [ $RC = 0 ] && [ "$(sql "SELECT count(*) FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.member WHERE r.rolname IN ('erin', 'jane.doe') AND am.roleid = 'grp'::regrole")" = 0 ]; then ok "a membership granted by another role is revoked when the user is not in the mapped group (also for a dotted name)"; else bad "a membership granted by another role is revoked when the user is not in the mapped group (also for a dotted name)"; fi
config "$BASE_CONFIG"

# The cron line itself, as the image installs it.
CRON_LINE=$(docker exec "$DB" sh -c "crontab -l | grep psql_reconcile_permissions" | sed 's/^[^a-z]*\* \* \* \* //')
docker exec "$DB" sh -c "$CRON_LINE"; RC=$?
if [ $RC = 0 ] && docker exec "$DB" crontab -l | grep -q "^0 \* \* \* \* .*psql_reconcile_permissions" && docker exec "$DB" grep -q "done:" /var/log/reconcile_permissions.log; then ok "the installed cron line runs the reconcile (hourly)"; else bad "the installed cron line runs the reconcile (hourly)"; fi

# Failures: nothing may change.
members readers alice erin carol
BEFORE=$(snapshot)
config "$BASE_CONFIG
PSQL_READ_SCHEMA_S2=ghost"
members readers alice erin carol george
reconcile
if [ $RC = 1 ] && grep -q "ghost" <<<"$OUT" && [ "$(snapshot)" = "$BEFORE" ]; then ok "a configured group missing from LDAP stops the run, nothing changes"; else bad "a configured group missing from LDAP stops the run, nothing changes"; fi
if docker logs "$DB" 2>&1 | grep -qE "(WARNING|AVISO): +psql_reconcile_permissions.*ghost"; then ok "the failure reaches the container log"; else bad "the failure reaches the container log"; fi

config "$BASE_CONFIG
PSQL_READ_SCHEMA_S2="
reconcile
if [ $RC = 1 ] && [ "$(snapshot)" = "$BEFORE" ]; then ok "a PSQL_* variable naming no group stops the run, nothing changes"; else bad "a PSQL_* variable naming no group stops the run, nothing changes"; fi

config "$BASE_CONFIG
PSQL_READ_SCHEMA_S2=gon"
reconcile
if [ $RC = 1 ] && grep -q "not posixGroup" <<<"$OUT" && [ "$(snapshot)" = "$BEFORE" ]; then ok "a group that is not a posixGroup stops the run, nothing changes"; else bad "a group that is not a posixGroup stops the run, nothing changes"; fi

config "$BASE_CONFIG
PSQL_WRITE_SCHEMA_LDAP_RECONCILE=writers"
reconcile
if [ $RC = 1 ] && [ "$(snapshot)" = "$BEFORE" ]; then ok "the reconcile's own schema cannot be configured, nothing changes"; else bad "the reconcile's own schema cannot be configured, nothing changes"; fi

config "$BASE_CONFIG
PSQL_READ_SCHEMA_PG_CATALOG=readers"
reconcile
if [ $RC = 1 ] && [ "$(snapshot)" = "$BEFORE" ]; then ok "a system schema cannot be configured, nothing changes"; else bad "a system schema cannot be configured, nothing changes"; fi

sql "CREATE ROLE danger NOLOGIN; GRANT pg_write_server_files TO danger; CREATE ROLE ownergrp NOLOGIN; GRANT app TO ownergrp;" >/dev/null
BEFORE=$(snapshot)
for target in POSTGRES DANGER APP OWNERGRP; do
	config "$BASE_CONFIG
PSQL_ALTER_GROUP_$target=readers
SKIP_ALTER_GROUP=false"
	reconcile
	if [ $RC = 2 ] && grep -q "privileged or a login role" <<<"$OUT" && [ "$(snapshot)" = "$BEFORE" ]; then ok "a privileged or login group role ($target) is refused, nothing changes"; else bad "a privileged or login group role ($target) is refused, nothing changes"; fi
done

config "$BASE_CONFIG"
members readers alice erin carol "Bad User"
reconcile
if [ $RC = 1 ] && [ "$(snapshot)" = "$BEFORE" ]; then ok "an untrusted username stops the run, nothing changes"; else bad "an untrusted username stops the run, nothing changes"; fi

members readers alice erin carol george
config "$BASE_CONFIG
LDAP_PASSWORD=wrong"
reconcile
if [ $RC = 1 ] && [ "$(snapshot)" = "$BEFORE" ]; then ok "a failed bind stops the run, nothing changes"; else bad "a failed bind stops the run, nothing changes"; fi

config "$BASE_CONFIG"
docker stop "$LDAP" >/dev/null
reconcile
if [ $RC = 1 ] && [ "$(snapshot)" = "$BEFORE" ]; then ok "LDAP down stops the run, nothing changes"; else bad "LDAP down stops the run, nothing changes"; fi
docker start "$LDAP" >/dev/null
# shellcheck disable=SC2034  # iteration only counts the retries
for iteration in $(seq 60); do docker exec "$LDAP" ldapsearch -x -H ldap://localhost -D "$ADMIN_DN" -w admin -b "$BASE" -s base dn >/dev/null 2>&1 && break; sleep 2; done

# A database error on one user skips that user only: carol owns an object in another
# database, which DROP OWNED cannot reach, so dropping carol fails; george, new in
# readers, is still created in the same run.
sql "CREATE DATABASE otherdb" >/dev/null
docker exec "$DB" psql -X -q -U postgres -d otherdb -c "CREATE TABLE keep(i int); ALTER TABLE keep OWNER TO carol;" >/dev/null
members readers alice erin george
reconcile
if [ $RC = 3 ] && grep -q "ERROR carol drop:" <<<"$OUT" && exists carol && exists george && managed george; then ok "a database error on one user skips that user (exit 3) and applies the rest"; else bad "a database error on one user skips that user (exit 3) and applies the rest"; fi
if [ "$(sql "SELECT count(*) FROM ldap_reconcile.permissions_audit WHERE action = 'ERROR' AND grantee = 'carol'")" -ge 1 ] && [ "$(sql "SELECT count(*) FROM ldap_reconcile.permissions_audit WHERE action = 'DROP_USER' AND grantee = 'carol'")" = 0 ]; then ok "the failed step is recorded as ERROR, and none of its changes"; else bad "the failed step is recorded as ERROR, and none of its changes"; fi
CAROL_KEEP=$(docker exec "$DB" psql -X -tA -U postgres -d otherdb -c "SELECT tableowner FROM pg_tables WHERE tablename = 'keep'")
if [ "$CAROL_KEEP" = carol ] && [ "$(sql "SELECT count(*) FROM ldap_reconcile.permissions_audit WHERE action = 'DROP_USER' AND grantee = 'carol'")" = 0 ] && ! can carol s1.t_a SELECT; then ok "carol's failed drop is rolled back, and her configured access is still revoked (she left LDAP)"; else bad "carol's failed drop is rolled back, and her configured access is still revoked (she left LDAP)"; fi
docker exec "$DB" psql -X -q -U postgres -d otherdb -c "DROP TABLE keep;" >/dev/null
reconcile
if [ $RC = 0 ] && ! exists carol; then ok "once the cause is gone the next run applies"; else bad "once the cause is gone the next run applies"; fi

# A role with CREATEROLE or CREATEDB is never taken over, even when LDAP names it.
sql "CREATE ROLE dbcreator LOGIN CREATEDB" >/dev/null
members readers alice erin george dbcreator
reconcile
if [ $RC = 0 ] && exists dbcreator && ! managed dbcreator; then ok "a CREATEDB role named in LDAP is not adopted"; else bad "a CREATEDB role named in LDAP is not adopted"; fi
members readers alice erin george

# Drops disabled.
config "$BASE_CONFIG
SKIP_DELETE=true"
members readers erin george
reconcile
if [ $RC = 0 ] && exists alice && grep -q "KEEP_USER alice" <<<"$OUT"; then ok "SKIP_DELETE=true keeps users that left LDAP"; else bad "SKIP_DELETE=true keeps users that left LDAP"; fi
if ! can alice s1.t_a SELECT && [ "$(sql "SELECT count(*) FROM pg_database d, aclexplode(d.datacl) x WHERE d.datname = 'appdb' AND x.grantee = 'alice'::regrole")" = 0 ]; then ok "a kept user loses the configured access (tables, direct database grants)"; else bad "a kept user loses the configured access (tables, direct database grants)"; fi

# Configuration removed: nothing is reconciled (no mass drop from a missing variable).
config "unset PSQL_READ_SCHEMA_S1 PSQL_READ_SCHEMA_S2_TABLE_T1 PSQL_WRITE_SCHEMA_S3"
reconcile
if [ $RC = 0 ] && grep -q "nothing to reconcile" <<<"$OUT" && exists erin; then ok "with the PSQL_* configuration removed the run does nothing"; else bad "with the PSQL_* configuration removed the run does nothing"; fi

# Every group empty: refused unless RECONCILE_ALLOW_EMPTY=true, then every managed user goes.
config "$BASE_CONFIG"
members readers; members writers; members temp
BEFORE=$(snapshot)
reconcile
if [ $RC = 1 ] && grep -q "RECONCILE_ALLOW_EMPTY" <<<"$OUT" && [ "$(snapshot)" = "$BEFORE" ]; then ok "every group empty at once is refused by default, nothing changes"; else bad "every group empty at once is refused by default, nothing changes"; fi
config "$BASE_CONFIG
RECONCILE_ALLOW_EMPTY=true"
reconcile
if [ $RC = 0 ] && ! exists alice && ! exists erin && ! exists george && ! exists frank; then ok "with RECONCILE_ALLOW_EMPTY=true, every group empty drops every managed user"; else bad "with RECONCILE_ALLOW_EMPTY=true, every group empty drops every managed user"; fi
if exists svc && exists handmade && exists app && exists postgres && exists ldap_managed; then ok "and leaves every unmanaged role"; else bad "and leaves every unmanaged role"; fi

# First run with every group empty: the legacy users it would adopt are not dropped.
sql "DROP ROLE ldap_managed; CREATE ROLE legacy LOGIN; GRANT USAGE ON SCHEMA s1 TO legacy; GRANT SELECT ON s1.t_a TO legacy;" >/dev/null
config "$BASE_CONFIG"
BEFORE=$(snapshot)
reconcile
if [ $RC = 1 ] && grep -q "first run" <<<"$OUT" && [ "$(snapshot)" = "$BEFORE" ] && exists legacy; then ok "every group empty on the first run is refused, the legacy users stay"; else bad "every group empty on the first run is refused, the legacy users stay"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
