# AGENTS.md

PostgreSQL images of the coldis platform (`coldis/infrastructure-transactional-repository`, GitHub
`coldis-org/infrastructure-transactional-repository`): the official `postgres:<version>-bookworm`
images with a pt_BR locale, contrib, LDAP user sync, cron, and boot scripts that tune the server to
the container's limits; plus a streaming replica, a major-version upgrade image and a tuner. No
application code; `pom.xml` (parent `org.coldis:configuration`) carries no build of its own.

Image layering: the repository images copy the `os_*` scripts out of `coldis/infrastructure-os`
in a build stage and build on `postgres:*-bookworm`; `repository-replica` and `repository-upgrade`
build `FROM` a released repository image (`coldis/infrastructure-transactional-repository:<tag>`).

## Layout

All under `src/main/infrastructure/`.

| Path | Holds |
|------|-------|
| `repository/Dockerfile3` .. `Dockerfile7` | PostgreSQL 14, 15, 16, 17, 18 (`postgres:18.6-bookworm` in `Dockerfile7`) |
| `repository/conf/` | `postgresql.conf`, `pg_hba.conf` (copied to `/tmp`, put into `PGDATA` at boot) |
| `repository/script/psql/` | `psql_init` (entrypoint), `psql_configure`, `psql_tune_cmd`, `psql_relocate`, `psql_update_conn`, `psql_reconcile_permissions` (+ `sql/`, `psql_install_reconcile`, `psql_users_add` entry point) |
| `repository/cron/cron_job` | Hourly LDAP permissions reconcile (`psql_reconcile_permissions.sh`, under flock) |
| `repository-replica/` | `Dockerfile5`..`7`, `psql_replica_init.sh` (`pg_basebackup` replica); no `conf/` of its own: `postgresql.conf` and `pg_hba.conf` come from the primary with the base backup |
| `repository-upgrade/` | Major-version migration image (`pg_upgrade`), pre-flight check; read its `README.md` |
| `repository-tuner/` | `FROM jfcoz/postgresqltuner`, nothing else |
| `*/service.json` | Marathon-style app definitions |

## Commands

No build script or CI. Each image builds from its folder, naming the Dockerfile:

```bash
docker build -f src/main/infrastructure/repository/Dockerfile7 src/main/infrastructure/repository
docker build -f src/main/infrastructure/repository-replica/Dockerfile7 src/main/infrastructure/repository-replica
docker build src/main/infrastructure/repository-upgrade
```

Upgrade pre-flight check, read-only, safe against production (from `repository-upgrade/README.md`):

```bash
PGPASSWORD=... docker run --rm -e PGPASSWORD --entrypoint ./psql_upgrade_check.sh \
  coldis/infrastructure-transactional-repository-upgrade:<tag> <host> <port> postgres
```

## Gotchas

- **Stay on bookworm.** Every `FROM postgres:` keeps the `-bookworm` suffix through every minor
  bump: plain `postgres:18` is trixie (glibc 2.41), and crossing glibc silently breaks
  collation-aware indexes that `pg_upgrade` carries over. Published 7.0.0–7.0.3 are trixie; 7.1.0
  is the first bookworm build, and the upgrade image cannot go below it.
- **Mount volumes at `/var/lib/postgresql`**, not at the data directory: only that layout can be
  migrated with `pg_upgrade --link`. A mount there needs an image with `psql_relocate.sh`; raise
  a derived image's `FROM` in the same change that moves its mount.
- **The repository image never migrates data.** Migration only happens through
  `repository-upgrade`. Raising it means raising its `FROM` tag and adding the version left behind
  to `PG_UPGRADE_FROM`. Derived images must not redeclare `ENTRYPOINT` or nothing is migrated.
- **Never point the upgrade image at the replica's volume**: the replica is the rollback.
- **`REPLICATION_LOCK_FILE` means two different files**: `replication_configured.lock` in
  `psql_replica_init.sh` and `psql_configure.sh`, `standby.signal` in `psql_update_conn.sh`.
  Removing the lock while the replica image starts makes it `rm -rf ${PGDATA}/*` and re-clone.
- **`postgresql.conf` is replaced at every start** when one exists in `PGDATA`, and `pg_hba.conf`
  is rendered with `envsubst`; edits made inside a running container do not survive.
- **`POSTGRES_ADMIN_PASSWORD` defaults to `postgres`** in the image, a real password on any
  deployment that never changed it; the upgrade refuses only an unset value.
- **Cron jobs see the boot environment** through `/etc/env_vars`, which `psql_init` writes with
  `env` before starting cron.

## Conventions

- One Dockerfile per supported major, numbered, in the same folder; scripts and config are shared
  across them. Comments in the Dockerfiles carry the reason for each pin; keep them current.
- Scripts are `#!/bin/sh`, copied to `/opt/psql-script` and run from there (`WORKDIR`,
  `ENTRYPOINT [ "./psql_init.sh" ]`); they are not linked into `/usr/bin`. The upgrade image
  makes them root-owned and read-only to the `postgres` user.
- Tunables are environment variables with a default in the Dockerfile `ENV` block (`*_PERC`,
  `*_MAX`), applied by `psql_tune_cmd` from `os_limits` output.
- Derived images pin an immutable release tag, never a moving one.

## Workspace

This repository expects `supersim-infrastructure-code-reviewer` checked out next to it
(`../supersim-infrastructure-code-reviewer`; clone it there from the internal Git host if it's
missing). The review-gate summary and the local review both live in it.

## Review

The gates are those of `src/agents/review/review.toml`, read from master, so a branch can't weaken
its own review: `security`, `platform-image`, `platform-runtime`, `platform-config` and the
`shellcheck` rule (severity `warning`, HIGH on failure). What each gate stops:
`../supersim-infrastructure-code-reviewer/local-review/GATES.md`. The PR description must name
every base image or tag, PostgreSQL version, default, port, cron schedule, mount and data path
changed, and whether a deployment needs a migration window.

Before pushing, run the local review: follow
`../supersim-infrastructure-code-reviewer/local-review/REVIEW.md`. It ends with
`local-check attest`. Push only when the developer asks.
