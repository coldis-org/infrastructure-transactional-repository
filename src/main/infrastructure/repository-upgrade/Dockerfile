# Migrates the data of a previous deployment to the newest PostgreSQL and then starts the
# database.
#
# Deployed in place of the repository image while the data is migrated, and replaced by it
# again on the next routine deployment: the migration is recorded on the volume, so this image
# does nothing on a second start and is never needed twice.
#
# There is a single Dockerfile because there is only ever one version worth migrating to, the
# newest one. Raising the repository module means raising the tag below and adding the version
# it leaves behind to PG_UPGRADE_FROM.
#
# The volume has to be mounted at /var/lib/postgresql, the folder holding the data directory,
# and not at the /var/lib/postgresql/data that was the data directory itself up to PostgreSQL
# 17. A volume mounted at the old path makes the container refuse to start, rather than write
# the migrated data outside the volume.

# From the newest repository image, which is the version the data is migrated to. The tag has to
# be raised along with the one of the repository module, and cannot be older than the release
# that made the lock tables follow the available memory: without it this image asks for gigabytes
# of shared memory on a small deployment and is killed by the kernel right after migrating.
FROM coldis/infrastructure-transactional-repository:7.0.2

# Makes the inherited configuration one this version accepts, so that this image can be deployed
# on its own and does not need a derived one built around it just to carry a configuration.
# psql_init.sh installs /tmp/postgresql.conf over the one of the migrated cluster, and the one
# the repository image ships still names wal_keep_segments, which PostgreSQL 13 removed, and
# preloads pg_hint_plan, which only the PostgreSQL 16 image installs. Either keeps the server
# from starting. The tuned command line passes wal_keep_size, so dropping the line loses nothing.
# Fixing conf/postgresql.conf in the repository module would make this unnecessary.
RUN sed -i \
	-e '/^wal_keep_segments/d' \
	-e "s/^shared_preload_libraries.*/shared_preload_libraries = ''/" \
	/tmp/postgresql.conf

# Copies the migration scripts, which the repository image does not carry: it holds no
# migration code at all, so a database can never migrate itself by accident.
COPY script/*.sh /opt/psql-script/
WORKDIR /opt/psql-script
RUN chown -R postgres:postgres /opt/psql-script && \
	chmod -R +x /opt/psql-script

# Installs the server binaries of every version still deployed anywhere: they are needed to
# read the catalog of the data they wrote, and nothing is downloaded while a database is
# starting. What gets migrated is the version the volume actually holds, so listing them all
# costs only image size.
ENV PG_UPGRADE_FROM="14 15 16 17"
RUN /opt/psql-script/psql_upgrade_install.sh

# Hard links the data files into the new cluster instead of copying them, as pg_upgrade --link
# and the image this module replaces both do: the migration then takes about the same time on a
# database of any size, and needs almost no room on the volume. Both clusters end up sharing
# their data blocks, which has two consequences.
#
# The old cluster cannot be started again — doing so corrupts both — so the only way back is a
# snapshot of the volume. Take one before deploying this image.
#
# An interruption while the files are being linked leaves the two clusters sharing blocks in a
# state neither can be started from. psql_upgrade.sh records that phase on the volume and
# refuses to run again until an operator restores the snapshot or sets UPGRADE_FORCE_RETRY.
#
# UPGRADE_MODE=copy leaves the old cluster intact and rolls back by redeploying the repository
# image, at the cost of room for a second copy of the data and of a migration that takes as
# long as the data is large. UPGRADE_MODE=auto picks copy when the volume has the room.
ENV UPGRADE_MODE=link

# Command.
ENTRYPOINT [ "./psql_upgrade_init.sh" ]
CMD [ "docker-entrypoint.sh", "postgres" ]
