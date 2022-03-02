# From Postgres.
FROM coldis/infrastructure-transactional-repository:2.2

# Copies init script.
COPY script/init.sh /
RUN chown -R postgres:postgres /init.sh && \
	chmod -R +x /init.sh
	
ENTRYPOINT ["/init.sh"]
CMD []


