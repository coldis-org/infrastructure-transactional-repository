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
| `repository/Dockerfile3` .. `Dockerfile7` | PostgreSQL 14, 15, 16, 17, 18 (`postgres:18.7-bookworm` in `Dockerfile7`) |
| `repository/conf/` | `postgresql.conf`, `pg_hba.conf` (copied to `/tmp`, put into `PGDATA` at boot) |
| `repository/script/psql/` | `psql_init` (entrypoint), `psql_configure`, `psql_tune_cmd`, `psql_memory` (memory guard and OOM targeting functions), `psql_memory_guard` (the guard's runner), `psql_relocate`, `psql_update_conn`, `psql_reconcile_permissions` (+ `sql/`, `psql_install_reconcile`, `psql_users_add` entry point) |
| `repository/cron/cron_job` | LDAP permissions reconcile every 30 minutes (`psql_reconcile_permissions.sh`, under flock) |
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

Host tests (no Docker; POSIX `sh`, as in the image):

```bash
sh src/test/infrastructure/repository/tune_test.sh          # tuner budget; TUNE_SCRIPT=<path> runs another copy
sh src/test/infrastructure/repository/memory_guard_test.sh  # memory guard and OOM targeting, against fake cgroup and /proc
```

Docker tests (manual; they create and remove their own containers):

```bash
bash src/test/infrastructure/repository-replica/replica_test.sh <replica-image> [replica-image-before]
# Memory guard simulation, scenarios S0 to S10 and S1U (see the script header); --build builds Dockerfile7
# (and Dockerfile4..6 for S8, the replica for S6) from a worktree, --image takes a built one:
bash src/test/infrastructure/repository/memory_guard_sim.sh --build . --scenarios S0,S1,S2 --out <dir>
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
- **Never `kill -9` the memory guard, or any other child of PID 1.** The postmaster treats a child
  it does not know that dies by a signal as a crashed backend and restarts every session (measured
  in simulation S5b). Stop the guard with TERM (it exits 0 and nothing happens), or pause it with
  the pause file. The image has no `kill`, `ps` or `pgrep` binaries; use the shell's built-in `kill`,
  for instance `docker exec <container> sh -c 'for d in /proc/[0-9]*; do grep -q psql_memory_guard "$d/cmdline" 2>/dev/null && kill -TERM "${d#/proc/}"; done'`,
  and restart it with `docker exec -d -u postgres <container> /opt/psql-script/psql_memory_guard.sh`.
- **Cron jobs see the boot environment** through `/etc/env_vars`, which `psql_init` writes with
  `env` before starting cron.

## Memory and out of memory

What a kernel kill costs: when the container reaches its memory limit, the kernel kills a process.
If that is any server process, the postmaster ends every other session and runs crash recovery,
refusing connections meanwhile; every client then reconnects at once. Ending one session with
`pg_terminate_backend` costs that session only. Three layers, all in `psql_tune_cmd.sh` and
`psql_memory.sh`:

- **Tuner budget.** Every server process is budgeted: connections (`CONNECTION_MEMORY` plus page
  tables for the shared buffers each maps), and the other server processes (worker slots,
  autovacuum, WAL senders, auxiliary) in a term of their own capped at
  `SERVER_PROCESSES_MEMORY_MAX_PERC` (10) of the budget; that term comes out of shared buffers and
  the other percentage settings, never out of `max_connections`. `work_mem` is split over
  `WORK_MEM_ACTIVE_PERC` (65) of the connections plus the parallel workers; below 100 it is an
  over-commit, stated at boot in a WARN with the worst case (`WORK_MEM_MAX` caps it;
  `ALTER ROLE ... SET work_mem` is the safer way to give one role more). No guard covers it by
  default (off below 18, dry-run on 18): a deployment close to its limit pins 100.
  `MAX_PARALLEL_WORKERS_PER_GATHER_MAX` (2) caps workers per query, since each takes its own
  `work_mem` per node. `IDLE_IN_TRANSACTION_SESSION_TIMEOUT` (30min) ends sessions left idle in a
  transaction. `superuser_reserved_connections` is 5, so administration and the guard get in when
  `max_connections` is exhausted.
- **Too little memory starts anyway** (7.3.0 refused to start). The settings shrink until the
  reserve (`MIN_RESERVED_MEMORY_PERC`, `MIN_RESERVED_MEMORY`) is kept; when that would leave them
  sized from under a tenth of the limit, `max_connections` goes down instead, 10% at a time, to a
  floor of `superuser_reserved_connections` + 5 (10). At the floor the rest shrinks to Postgres'
  minimums, and if the reserve still cannot be kept the server starts with one
  `WARN: NOT ENOUGH MEMORY` line giving requested and applied connections and the reserve left.
  The memory guard is then the remaining protection. A **standby** cannot go below its primary's
  `max_connections`, `max_worker_processes`, `max_wal_senders`, `max_prepared_transactions` and
  `max_locks_per_transaction` while `hot_standby` is on (PostgreSQL pauses or refuses recovery):
  `psql_replica_init.sh` reads them from `pg_control` and passes them as floors, and only the
  rest shrinks. A replica much smaller than its primary therefore runs without its reserve; give it
  memory, or lower those settings on the primary. `POSTGRES_TUNE_FAILED` is never set by a
  shortfall any more.
- **PostgreSQL 18 only, by default.** The memory guard and OOM targeting are simulated and
  enabled in `Dockerfile7` only. `Dockerfile3`..`6` ship them with `MEMORY_GUARD_ENABLED=false` and
  `OOM_TARGETING_ENABLED=false`; they can be turned on there, untested. The tuner changes apply to
  all five.
- **Memory guard** (`psql_memory_guard.sh`, started in the background by both init scripts just
  before the `exec`, as `postgres`, a child of the postmaster). It reads the cgroup (v2, or v1;
  which one and which limit below) every `MEMORY_GUARD_INTERVAL` (2 s; `FAST_INTERVAL` 0.5 s under pressure), counting use without
  the file page cache. Stages, by share of the limit: **idle** (`MEMORY_GUARD_IDLE_PERC`, 85)
  terminates idle sessions holding the most private memory (`RssAnon` + `VmPTE`), up to
  `IDLE_BATCH` a pass and `IDLE_MAX_PER_MIN`; **active** (92) also cancels the largest busy query,
  then terminates it after `CANCEL_GRACE`; **critical** (96) terminates the largest sessions of any
  state until enough is freed. It only ends non-superuser client backends holding at least
  `MIN_PRIVATE_MB` (default `CONNECTION_MEMORY`), never roles in `MEMORY_GUARD_EXCLUDE_USERS`, and
  only through `pg_cancel_backend` / `pg_terminate_backend`, re-checked by pid and
  `backend_start` at action time. Below the first threshold a pass reads the cgroup files and
  nothing else; above it one `pg_stat_activity` query lists the candidates (idle ones only in
  stage idle) and only their `/proc/<pid>/status` is read. It runs at nice 10 and best-effort I/O
  priority 7 (never the idle class, which a busy database starves), keeps its state in `/dev/shm`,
  and when a pass exceeds `MEMORY_GUARD_TICK_BUDGET_MS` waits at least that long before the next
  (up to `MEMORY_GUARD_MAX_INTERVAL`), acting from the last ranking in between. Every line starts with `MEMORY_GUARD:`
  (`grep MEMORY_GUARD:`), in English, as `event=<name> key=value`; action lines carry `usename`,
  `application_name`, `private_mb`, the `query_id` and a query prefix of `MEMORY_GUARD_QUERY_CHARS`
  (120; 0 for none). The prefix never holds a literal: it ends before the statement's first quote,
  dollar sign or comment opener, and the numbers before that become `?` (for example
  `SELECT id FROM orders WHERE id = ? AND name =`). The tuner sets `compute_query_id=on`, so the id is always there; where
  `pg_stat_statements` is preloaded, `SELECT query FROM pg_stat_statements WHERE queryid = <id>`
  gives the full normalised text.
  - **Ships in dry-run** (`MEMORY_GUARD_MODE=dry-run`): it logs every action with
    `result=dry-run` and signals nothing. Set `enforce` to act. Roll out in dry-run, read the
    `event=status` lines (`peak_pct`) for a while, set the thresholds a few points above the
    normal peak, then enforce on the next restart.
  - **Pause without a restart:** `touch /tmp/memory_guard.pause` (`MEMORY_GUARD_PAUSE_FILE`) in
    the container, as root (`docker exec`'s default) or `postgres`; a file of any other owner is
    ignored; it keeps logging, with `result=paused`, and signals nothing until the file is
    removed. `MEMORY_GUARD_ENABLED=false` turns it off at the next start.
  - `MEMORY_GUARD_IDLE_PERC` (85) is 100 minus the default 15% reserve: a deployment with a
    smaller reserve raises the thresholds to match. On small containers lower all three (4% of
    1 GB is 40 MB, a single query). A steady state above the idle threshold means sizing is
    wrong: raise the threshold or lower connections, do not live with it.
  - With `HUGE_PAGES=on`, shared buffers are normally not charged to the memory cgroup, so use
    reads lower against the same limit.
  - **Which cgroup, which limit.** The cgroup is the mount's own (`/sys/fs/cgroup`, a private
    cgroup namespace) when it has a limit, else the process's own one from `/proc/self/cgroup`
    (`0::<path>` on v2, the line listing `memory` on v1, under the mount: a container that sees
    the host's tree). An unlimited mount is kept only when it is known to be the container's own
    (that own folder is the mount, or is not under it, as with v1 Docker's bind mount); when the
    own folder is another one under it, or unknown, the guard stays off. With no limit anywhere (`docker run` without `-m`, `memory.max=max`, or no
    `memory.max` at the root of a namespace) the limit is the budget the tuner sized the server
    for: `MAX_MEMORY` (kB) when set, else the chain of `os_limits` `available_memory` (the guard
    runs that script, found on `PATH` as `psql_tune_cmd.sh` finds it; the boot-time OOM targeting,
    run as root, does not run it and only names the source): `NOMAD_MEMORY_LIMIT`
    (`MEMORY_LIMIT_VAR`, scaled by `MEMORY_LIMIT_UNIT_PERC`), else `HOST_MEM_PERC` (20) % of
    `MemTotal`. **That
    budget is guard-only: the kernel does not enforce it**; the guard keeps the server within it,
    and there is no kernel kill behind it. Use is always the cgroup's (`memory.current` or
    `usage_in_bytes` less page cache); with no cgroup use readable the guard stays off
    (`reason=no_cgroup`) rather than read the host's, which is every tenant's. `event=start`
    and `event=oom_target` carry `limit_source=cgroup|max_memory|nomad_var|host_share` and
    `cgroup_path=<folder>`; a fallback budget adds one `WARN: event=limit_fallback`. Simulation
    S1U runs S1 with no `-m` and `NOMAD_MEMORY_LIMIT=1024`.
  - Superuser sessions are never ended; a database whose heavy sessions are superusers gets
    `event=no_candidate` only.
  - It is a polling loop: in simulation S3 (1 GB, 2 CPUs, three sessions growing at once) it held
    growth up to 12% of the limit per second (about 120 MB/s) and lost at 25%/s (one run lost at
    12%/s). Faster growth reaches the kernel first. A full pass over 2,000 idle backends (simulation S7, 8 GB, 4 CPUs)
    took 100 to 140 ms of CPU, 250 to 350 ms extrapolated to 5,000.
- **OOM targeting** (`psql_oom_target`, `OOM_TARGETING_ENABLED`, `OOM_CHILD_SCORE_ADJ` 100):
  exports `PG_OOM_ADJUST_FILE` / `PG_OOM_ADJUST_VALUE`, so every child of the postmaster raises its
  own `oom_score_adj` and the kernel kills a child, never PID 1, and the container survives. It
  only makes the victim deterministic: any kill is still crash recovery. The simulation found that
  without it the kernel may pick the postmaster when backends are small (S0B: the 7.3.0 image lost
  PID 1, and the container with it). 100 rather than more because in a host-level OOM a larger
  value makes the database the host's first victim. Void when the runtime sets
  `memory.oom.group=1` (boot WARN).

Infra notes, outside the image:
- A cgroup `memory.high` somewhat below `memory.max` throttles allocation and gives the guard
  time. Docker and the usual schedulers do not expose it and the container cannot set its own; it
  is written on the host. While throttled every process in the container stalls, the guard's
  queries included. Optional, not measured here (simulation S9 is manual).
- A pooler (PgBouncer or similar) is the structural fix: fewer, reused backends. Out of scope for
  the image.

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
