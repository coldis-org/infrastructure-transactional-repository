# From Postgres.
FROM coldis/infrastructure-transactional-repository:3.3

# Copies init script.
COPY script/psql_replica_init.sh /
RUN chown -R postgres:postgres /psql_replica_init.sh && \
	chmod -R +x /psql_replica_init.sh
	
ENTRYPOINT ["/psql_replica_init.sh"]
CMD [ "docker-entrypoint.sh", "postgres" ]


