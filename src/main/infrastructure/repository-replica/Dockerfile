# From Postgres.
FROM coldis/infrastructure-transactional-repository

# Copies init script.
COPY script/init.sh /
RUN chown -R postgres:postgres /init.sh && \
	chmod -R +x /init.sh
	
ENTRYPOINT ["/init.sh"]
	


