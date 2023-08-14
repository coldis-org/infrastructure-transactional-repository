# From Postgres.
FROM coldis/infrastructure-transactional-repository:4.2.0

# Copies init script.
COPY script/psql_replica_init.sh /opt/psql-script
RUN chown -R postgres:postgres /opt/psql-script && \
	chmod -R +x /opt/psql-script
	
ENTRYPOINT [ "./psql_replica_init.sh" ]
CMD [ "gosu", "postgres" , "postgres" ]


