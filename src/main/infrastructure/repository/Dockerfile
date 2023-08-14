# From Postgres.
FROM postgres:15.4-bookworm

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

# Command.
ENTRYPOINT [ "./psql_init.sh" ]
CMD [ "docker-entrypoint.sh", "postgres" ]
