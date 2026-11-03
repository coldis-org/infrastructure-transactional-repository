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
