# From Debian.
FROM coldis/infrastructure-os:1.0.0 as debian

# From Postgres.
FROM postgres:15.13-bookworm

# Sets locale and UTF-8 charset.
ENV TZ=America/Sao_Paulo \
	LANG_NAME=pt_BR \
	LANG_FILE=pt_BR.UTF-8 \
	LANG=pt_BR.utf8 \
	LANGUAGE=pt_BR:pt
RUN localedef -i ${LANG_NAME} -c -f UTF-8 -A /usr/share/locale/locale.alias ${LANG_FILE} && \
	cp /usr/share/zoneinfo/${TZ} /etc/localtime

# Installs Postgres contrib, LDAP tools and cron.
RUN apt-get update && \
	apt-get install -y --no-install-recommends \
		postgresql-contrib-${PG_MAJOR} ldap-utils gettext cron && \
	apt-get clean -y && \
	rm -rf /var/lib/apt/lists/*

COPY cron /etc/cron.d
RUN chmod -R 0644 /etc/cron.d/ \
	&& crontab /etc/cron.d/cron_job

# Copies the server configuration.
COPY conf /tmp
RUN chown -R postgres:postgres /tmp

# Copies init script.
COPY --from=debian /opt/os-script /opt/os-script
COPY --from=debian /usr/bin/os* /usr/bin
RUN mkdir -p /opt/psql-script	
COPY script/psql /opt/psql-script
WORKDIR /opt/psql-script
RUN chown -R postgres:postgres /opt/psql-script && \
	chmod -R +x /opt/psql-script
	
ENV POSTGRES_ADMIN_USER=postgres\
    POSTGRES_ADMIN_PASSWORD=postgres\
	MAX_CONNECTIONS=300\
	MAX_WAL_SENDERS_CONN_PERC=5\
	CPU_WORK_PERC=300\
	MAX_WORKER_PROCESSES=\
	MAX_WORKER_PROCESSES_PERC=170\
	MAX_PARALLEL_WORKERS_PERC=100\
	MAX_PARALLEL_MAINTENANCE_WORKERS_PERC=40\
	AUTOVACUUM_MAX_WORKERS_PERC=20\
	MAX_PARALLEL_WORKERS_PER_GATHER_PERC=20\
	MIN_RESERVED_MEMORY_PERC=15\
	MIN_RESERVED_MEMORY=262144\
	WAL_BUFFERS_PERC=3\
	WAL_BUFFERS_MAX=16384\
	WAL_WRITER_FLUSH_AFTER_PERC=3\
	WAL_WRITER_FLUSH_AFTER_MAX=131072\
	WAL_DECODE_BUFFER_SIZE_PERC=3\
	WAL_DECODE_BUFFER_SIZE_MAX=131072\
	TOTAL_LOGICAL_DECODING_WORK_MEM_PERC=10\
	LOGICAL_DECODING_WORK_MEM_MAX=262144\
	MIN_WAL_SIZE_DISC_PERC=1\
	MIN_WAL_SIZE_MAX=32768\
	MAX_WAL_SIZE_DISC_PERC=1\
	MAX_WAL_SIZE_MAX=32768\
	MAX_SLOT_WAL_KEEP_SIZE_MAX=512000\
	WAL_KEEP_SIZE_DISC_PERC=2\
	MAX_SLOT_WAL_KEEP_SIZE_DISC_PERC=10\
	SHARED_BUFFERS_PERC=25\
	EFFECTIVE_CACHE_SIZE_PERC=50\
	TOTAL_WORK_MEM_PERC=30\
	TOTAL_MAINTENANCE_WORK_MEM_PERC=20\
	MIN_DYNAMIC_SHARED_MEMORY_PERC=2\
	OVERWRITE_TUNED_ARGS=true
	
# Command.
ENTRYPOINT [ "./psql_init.sh" ]
CMD [ "docker-entrypoint.sh", "postgres" ]
