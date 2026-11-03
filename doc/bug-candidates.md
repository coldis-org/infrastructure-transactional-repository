# Bug candidates

Observed on 2026-11-03 while configuring the code review for this repository (AGENTS.md and
`src/agents/review/review.toml`). These are **candidates**: noticed while reading, not verified,
not triaged. Credentials are named by location only. Remove an entry once it is confirmed and
tracked elsewhere, or found not to be a bug.

- `repository-replica/Dockerfile6` builds `FROM ...:5.0.11`, older than `Dockerfile5`'s 5.0.12.
- `repository-replica/conf/` is not copied by any replica Dockerfile.
- `repository/service.json` still mounts `/var/lib/postgresql/data`, which `repository-upgrade/README.md` says blocks `pg_upgrade --link`.
- `psql_users_add.sh` builds a list with `echo "a\nb"`, which dash and bash expand differently.
- `psql_init.sh` echoes the full `exec` line, including the admin password, to stdout.
- The daily `psql_users_*` cron jobs send their output to `/dev/null`.
- `repository-replica/script/psql_replica_init.sh:106` runs `. ./psql_update_conn.sh --skip-reload`; the dot command takes no arguments in dash, so the flag never arrives and the replica reloads a server that has not started (fixed the same way in `psql_init.sh` on 2026-11-03).
- `conf/pg_hba.conf` (rewritten into PGDATA on every boot) allows `host all all 0.0.0.0/0 md5` and `host replication replicator 0.0.0.0/0 md5`; PostgreSQL 18 deprecates md5 in favour of scram-sha-256.
