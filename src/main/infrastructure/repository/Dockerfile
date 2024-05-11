# From Postgres.
FROM postgres:16.3-bookworm

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
RUN mkdir -p /opt/psql-script	
COPY script/psql /opt/psql-script
WORKDIR /opt/psql-script
RUN chown -R postgres:postgres /opt/psql-script && \
	chmod -R +x /opt/psql-script
	
ENV MAX_CONNECTIONS=1000\
	MAX_WAL_SENDERS_RATIO=100\
	MAX_WORKER_PROCESSES=\
	MAX_WORKER_PROCESSES_RATIO=1\
	MAX_PARALLEL_WORKERS_RATIO=1\
	MAX_PARALLEL_MAINTENANCE_WORKERS_RATIO=4\
	AUTOVACUUM_MAX_WORKERS_RATIO=4\
	MAX_PARALLEL_WORKERS_PER_GATHER_RATIO=4\
	WAL_BUFFERS_RATIO=128\
	WAL_BUFFERS_MAX=16384\
	WAL_WRITER_FLUSH_AFTER_RATIO=64\
	WAL_WRITER_FLUSH_AFTER_MAX=131072\
	WAL_DECODE_BUFFER_SIZE_RATIO=64\
	WAL_DECODE_BUFFER_SIZE_MAX=131072\
	LOGICAL_DECODING_WORK_MEM_RATIO=64\
	LOGICAL_DECODING_WORK_MEM_MAX=262144\
	SHARED_BUFFERS_RATIO=5\
	EFFECTIVE_CACHE_SIZE_RATIO=2\
	TOTAL_WORK_MEM_RATIO=8\
	TOTAL_MAINTENANCE_WORK_MEM_RATIO=16\
	OVERWRITE_TUNED_ARGS=true
	
# Command.
ENTRYPOINT [ "./psql_init.sh" ]
CMD [ "docker-entrypoint.sh", "postgres" ]
