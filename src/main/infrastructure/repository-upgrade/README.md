# Migrating a repository deployment to a new PostgreSQL major version

This module builds an image that migrates the data of a deployment to the PostgreSQL version of
the repository image it derives from, and then starts the database. It is deployed in place of
the repository image for the migration, and replaced by it again afterwards.

The repository image rewrites no catalog and carries no binary of an older version, so a database
can never migrate itself by accident: a migration only happens when someone deploys this image on
purpose. What the repository image does do on its own is move a cluster of its **own** version
into the data directory it expects, which is a rename and not a migration — see below.

## Mount the volume at `/var/lib/postgresql`

PostgreSQL 18 keeps its data in a folder named after the major version,
`/var/lib/postgresql/18/docker`, where earlier versions kept it at `/var/lib/postgresql/data`.
Both a volume mounted at `/var/lib/postgresql` and one mounted at the data directory itself work
for a database that is installed fresh, so either looks fine until the first major upgrade.

Only the first one can ever be upgraded. `pg_upgrade --link` hard links the data files of the old
cluster into the new one, and hard links do not cross filesystems: the two clusters have to fit
side by side on the volume. A volume mounted at the data directory leaves no room beside it, and
the migration is impossible without moving every byte somewhere else first. This is also what the
upstream image recommends, and for the same reason — it is the layout that allows
`pg_upgrade --link` "without mount point boundary issues".

So `/var/lib/postgresql` is the layout to use everywhere, including for databases installed fresh
on 18: it is the one that leaves the door open for 19.

**Changing the mount of a volume that already holds data is not enough by itself.** The data has
to be moved into the versioned folder, and mounting somewhere else moves nothing — the server
finds a cluster where it expects a folder and refuses to start. Which image does the moving
depends on the version on the volume:

| what the volume holds | deploy | what happens |
| --- | --- | --- |
| a cluster of the image's own version | the **repository** image | `psql_relocate.sh` moves it into the versioned folder, a rename, about a second |
| a cluster of an older version | the **repository-upgrade** image | `pg_upgrade` migrates it, then the repository image goes back on the next release |

A database already running 18 therefore never needs this module: change its mount to
`/var/lib/postgresql` and redeploy its usual image. `psql_relocate.sh` refuses to touch data of a
version it cannot read and says which image to deploy instead, so getting this wrong costs a
failed deployment and not data.

## What the migration does

`psql_upgrade_init.sh` runs `psql_upgrade.sh` and then hands off to the regular `psql_init.sh`:

1. finds the data of the previous deployment on the volume and moves it aside (a rename, not a
   copy) to `.pg_upgrade_old_<version>`
2. starts and stops the old cluster once, to finish any pending crash recovery
3. initializes the new cluster, matching the encoding, collation and data checksum setting of
   the old one
4. runs `pg_upgrade --link`, so the new cluster shares the data files of the old one
5. sets the admin password and updates the extensions, on a private socket with no TCP
6. drops the old data and records the migration in `.pg_upgrade_state` on the volume

The state file makes the migration run once: a container that starts again finds it `done` and
hands over to `psql_init.sh` immediately.

## Before you book a window

**Run the pre-flight check.** It reads the schema over the network, rebuilds it in a throwaway
cluster and runs `pg_upgrade --check` against it. It does not deploy anything, does not touch
the deployment, and can be run against production at any time:

```sh
PGPASSWORD=... docker run --rm \
	--entrypoint ./psql_upgrade_check.sh \
	coldis/infrastructure-transactional-repository-upgrade:<tag> \
	<host> <port> postgres
```

It exits non-zero when something would block the migration. The case it is most useful for is
an extension the deployment uses and the new image does not carry — `pg_upgrade` fails on that,
and finding out during the window is expensive.

It reports the catalog, which is where `pg_upgrade --check` looks. When the schema does not
rebuild cleanly it says so, rather than reporting a clean result it cannot back.

**Point it at a replica.** Physical replication copies the catalog block for block, so a replica
answers the same as the primary — checked against both, the reports are identical. That is what
makes this runnable from a workstation that only reaches the replicas, and it keeps the dump off
the primary.

**It needs to read every table's definition**, and nothing else: `pg_read_all_data` is enough, no
superuser. A role without it fails on the first table it cannot read and the check stops there,
rather than reporting on a schema it only partly rebuilt. Roles are read without their passwords,
so no hash from the deployment is written to the machine running this.

**Estimate the window.** `pg_upgrade --link` creates directory entries instead of copying data,
so the time it takes follows the number of relations and not the size of the database:

```sql
SELECT count(*) FROM pg_class WHERE relkind IN ('r','i','m','t','p');
```

Measured at roughly 1.2 ms per relation, on top of about 5 s of fixed cost. A database of any
size with 500 thousand relations lands around ten minutes.

**Check the deployment carries a configuration valid for the new version.** Images that derive
from the repository image usually copy a `postgresql.conf` of their own, and it has to be one
the new server accepts — a parameter a later major version removed keeps it from starting.

## Preparation

1. Raise the `FROM` tag of this module to the repository image of the version to migrate to, and
   add the version being left behind to `PG_UPGRADE_FROM`.
2. Point the deployment at this image. For a deployment that derives from the repository image,
   that means changing the `FROM` line of its own Dockerfile and cutting a release — the rest of
   the derived image, its configuration and its scripts, stays as it is.
3. Mount the volume at `/var/lib/postgresql`, for the reason above. The container refuses to
   start when it is mounted anywhere else, rather than writing the migrated data outside the
   volume, so a forgotten mount costs a failed deployment and not data.
4. **Leave the replica's mount alone.** The replica stays on the old version, and its data is at
   the old path. It is the rollback, and remounting it destroys that.

## The window

```
 1. stop the application, so no writes reach the database
 2. confirm the replica caught up:
        primary: SELECT pg_current_wal_lsn();
        replica: SELECT pg_last_wal_replay_lsn();
    the two have to match — promoting a replica that is behind loses committed transactions
 3. scale the replica job to 0, so nothing can restart it and rebuild it while it is the fallback
 4. take a snapshot of the volume; the API call returns in seconds and the copy runs in the
    background, so this does not add to the window
 5. deploy the upgrade image, with the volume mounted at /var/lib/postgresql
 6. follow the logs to "PostgreSQL <old> data migrated to <new>"
 7. check the data, then let traffic back in
```

## Rolling back

The new cluster shares its data files with the old one, so the old cluster cannot be started:
the fallback is the replica, not the volume.

1. remove **both** control files from the replica's volume:
   - `standby.signal` — this is the one that matters, it is what keeps the server in recovery
   - `replication_configured.lock` — harmless here, removed only so nothing later mistakes the
     volume for a replica that has to be rebuilt
2. start a job on that volume with the **repository** image (the deployment's own derived image),
   mounted at the path the data actually sits at, which for PostgreSQL 17 and earlier is
   `/var/lib/postgresql/data`
3. point the application at it

**Never point the upgrade image at the replica's volume.** It would find data of an older version
and start migrating the fallback.

The volume of the failed primary still holds a half-migrated cluster; `.pg_upgrade_state` says
which phase it stopped at. Clear it before trying again.

## After a successful migration

- **Rebuild the replica from scratch.** `pg_upgrade` gives the cluster a new system identifier,
  so the old replica can never follow it again. A fresh volume is enough: `psql_replica_init.sh`
  finds no `replication_configured.lock` and takes a full `pg_basebackup`.
- **Watch the query plans.** `pg_upgrade` does not carry the planner statistics over.
  `psql_upgrade.sh` rebuilds them with `vacuumdb --analyze-in-stages` in the background, but on a
  large database the server is up and planning badly until the first stage finishes. Consider
  running that stage before letting traffic in.
- **Move the deployment back to the repository image** on the next routine release. Leaving it on
  the upgrade image is harmless — the migration is recorded on the volume and does not run again
  — but it carries binaries it no longer needs.

## Traps

**An interruption while the files are being linked** leaves both clusters sharing blocks in a
state neither can be started from. `psql_upgrade.sh` records that phase and refuses to run again
until an operator restores the snapshot or sets `UPGRADE_FORCE_RETRY=true`. This is the one
failure the snapshot is there for.

**Removing `replication_configured.lock` while the replica image is what starts** makes
`psql_replica_init.sh` run `rm -rf ${PGDATA}/*` and take a fresh base backup. On the volume that
is holding your rollback, that is the command that destroys it. The rollback above avoids this by
starting the repository image instead, which never reads that file.

Note that `REPLICATION_LOCK_FILE` names `replication_configured.lock` in `psql_replica_init.sh`
and `psql_configure.sh`, and `standby.signal` in `psql_update_conn.sh`. Same variable, different
files, and only one of them promotes anything.

**PostgreSQL 18 images are built on Debian trixie** (glibc 2.41) while 14 to 17 are built on
bookworm (glibc 2.36). Collation-aware indexes carry the sort order of the glibc they were built
with, and `pg_upgrade` does not rebuild them: after the migration the server reports a collation
version mismatch on every connection, and text indexes can silently return incomplete results
until they are reindexed. On a large database that is days of work. Building the repository image
`FROM postgres:<version>-bookworm` keeps glibc at 2.36 and the question does not arise.

**Do not copy the mount of an existing PostgreSQL 18 job as a model.** A database installed
fresh on 18 may well be mounted at `/var/lib/postgresql/18/docker`, which works for it and makes
every future major upgrade impossible. See the section at the top.

**`UPGRADE_MODE` can be changed per deployment** without rebuilding, through the environment of
the job: `copy` leaves the old cluster intact and rolls back by redeploying the previous image,
at the cost of room on the volume for a second copy of the data and of a migration that takes as
long as the data is large. `auto` picks `copy` when the volume has the room.
