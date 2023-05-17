# From Postgres.
FROM coldis/infrastructure-transactional-repository:4.1

# Copies init script.
COPY script/init.sh /
RUN chown -R postgres:postgres /init.sh && \
	chmod -R +x /init.sh
	
ENTRYPOINT ["/init.sh"]
CMD []


