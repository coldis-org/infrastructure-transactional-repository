# From Postgres.
FROM coldis/infrastructure-transactional-repository:5.0.9

# Copies init script.
COPY script/*.sh /opt/psql-script
RUN chown -R postgres:postgres /opt/psql-script && \
	chmod -R +x /opt/psql-script
	
# Port.
ENV COPY_PORT=5432
	
ENTRYPOINT [ "./psql_replica_init.sh" ]
CMD [ "gosu", "postgres" , "postgres" ]


