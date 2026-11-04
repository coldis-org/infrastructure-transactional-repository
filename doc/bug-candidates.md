# Bug candidates

Observed on 2026-11-03 while configuring the code review for this repository (AGENTS.md and
`src/agents/review/review.toml`). These are **candidates**: noticed while reading, not verified,
not triaged. Credentials are named by location only. Remove an entry once it is confirmed and
tracked elsewhere, or found not to be a bug.

- `repository-replica/Dockerfile6` builds `FROM ...:5.0.11`, older than `Dockerfile5`'s 5.0.12.
- `repository-replica/conf/` is not copied by any replica Dockerfile.
- `repository/service.json` still mounts `/var/lib/postgresql/data`, which `repository-upgrade/README.md` says blocks `pg_upgrade --link`.
- `psql_init.sh` echoes the full `exec` line, including the admin password, to stdout.
- `repository-replica/script/psql_replica_init.sh:106` runs `. ./psql_update_conn.sh --skip-reload`; the dot command takes no arguments in dash, so the flag never arrives and the replica reloads a server that has not started (fixed the same way in `psql_init.sh` on 2026-11-03).
- `conf/pg_hba.conf` (rewritten into PGDATA on every boot) allows `host all all 0.0.0.0/0 md5` and `host replication replicator 0.0.0.0/0 md5`; PostgreSQL 18 deprecates md5 in favour of scram-sha-256.
- `Dockerfile3` (PostgreSQL 14) does not boot: `psql_tune_cmd.sh` passes `wal_decode_buffer_size`, which exists only from 15 (observed 2026-11-04).

Follow-ups from the review of the LDAP permissions reconcile (2026-11-04), accepted at merge:
- `reconcile_permissions.sql` is installed with `CREATE OR REPLACE`; a future change to its parameter names or `RETURNS TABLE` will fail the install (and every hourly repair) until the old function is dropped. Install in one transaction with `DROP FUNCTION IF EXISTS` first.
- The 90% statement-timeout ceiling leaves one `lock_timeout` (30s) of headroom and is not checked inside a single drop or the database/schema grants.
- The boot install in `psql_configure.sh` runs outside the reconcile flock and can race a cron repair install during boot.
- The on-demand "update database users" pipeline (supersim-infrastructure-continuous-integration) calls `psql_users_add.sh`, which now exits 3 on ERROR/DEFERRED and 75 on a lock-wait timeout; check how the pipeline treats those.
- LDAP binds over plaintext `ldap://` when `LDAP_HOST` has no scheme (as the old scripts did); no `-ZZ`.
- The reconcile and install scripts fall back to the admin password `postgres` when `POSTGRES_ADMIN_PASSWORD` is unset.
- Write access grants `TRIGGER` (and `MAINTAIN` on 17+) with schema `CREATE`: a writer can run code as whoever modifies an application table (as the old `GRANT ALL` did).
- Users kept with `SKIP_DELETE=true` stay `LOGIN`.
- A dropped user's objects go to `POSTGRES_DEFAULT_USER`; a `SECURITY DEFINER` reassignment is neutralised, but the target role then owns whatever the user built.
- `reconcile_test.sh` uses `osixia/openldap:1.5.0` (tag, not digest; unmaintained since 2021).
