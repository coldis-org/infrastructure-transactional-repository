# From Postgres.
FROM postgres:11.2

# Installs Postgres contrib.
RUN apt-get update && \
	apt-get install -y --no-install-recommends \
		postgresql-contrib-${PG_MAJOR} && \
	apt-get clean -y && \
	rm -rf /var/lib/apt/lists/*

# Sets locale and UTF-8 charset.
ENV TZ=America/Sao_Paulo \
	LANG_NAME=pt_BR \
	LANG_FILE=pt_BR.UTF-8 \
	LANG=pt_BR.utf8 \
	LANGUAGE=pt_BR:pt
RUN localedef -i ${LANG_NAME} -c -f UTF-8 -A /usr/share/locale/locale.alias ${LANG_FILE} && \
	cp /usr/share/zoneinfo/${TZ} /etc/localtime

# Copies the server configuration.
COPY conf /tmp
RUN chown -R postgres:postgres /tmp

# Copies init script.
COPY script/init.sh /docker-entrypoint-initdb.d/
RUN chown -R postgres:postgres /docker-entrypoint-initdb.d/


