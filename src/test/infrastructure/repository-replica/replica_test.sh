#!/bin/bash

# Tests for a replica smaller than its primary (psql_replica_init.sh). A standby refuses to start
# when max_connections, max_worker_processes or max_locks_per_transaction is lower than on its
# primary, and each side tunes them from its own MAX_CPU / MAX_MEMORY / MAX_CONNECTIONS. They run
# on the host and drive a "big" primary and "small" replicas on a private network:
#
#   docker build -t replica-test -f src/main/infrastructure/repository-replica/Dockerfile7 \
#     src/main/infrastructure/repository-replica
#   bash src/test/infrastructure/repository-replica/replica_test.sh replica-test [replica-before]
#
# PRIMARY_IMAGE overrides the primary (default: the base the replica Dockerfile7 builds FROM).
# With a second image (the replica built before this change), it also checks that one refuses to
# start, so the suite proves what it fixes. Needs docker; creates and removes its containers,
# volumes and network. Exits non-zero when any test fails.

IMAGE=${1:?usage: replica_test.sh <replica-image> [replica-image-before]}
IMAGE_BEFORE=${2:-}
PRIMARY_IMAGE=${PRIMARY_IMAGE:-coldis/infrastructure-transactional-repository:7.1.0}
PREFIX=replica-test-$$
NET=$PREFIX-net; PRIMARY=$PREFIX-primary; REPLICA=$PREFIX-replica
# Test-only credential for the throwaway replication user.
REPLICATOR_PASSWORD=test-replicator-$$
pass=0; fail=0

ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
cleanup() {
	docker rm -f -v "$PRIMARY" "$REPLICA" >/dev/null 2>&1
	docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

# Waits until the container accepts connections; fails if it exits or 120s pass.
wait_ready() {
	# shellcheck disable=SC2034  # iteration only counts the retries
	for iteration in $(seq 60); do
		[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ] || return 1
		docker exec "$1" pg_isready -q -h 127.0.0.1 2>/dev/null && return 0
		sleep 2
	done
	return 1
}
# Waits until the container has exited; fails if 120s pass. docker wait blocks on the exit itself,
# where polling .State.Running can catch a container that has not started running yet.
wait_stopped() { timeout 120 docker wait "$1" >/dev/null 2>&1; }
sql() { docker exec "$1" psql -X -U postgres -h 127.0.0.1 -tAc "$2" 2>/dev/null; }
setting() { sql "$1" "SELECT current_setting('$2')"; }
# Starts a small replica (2 CPUs, 100 connections, the given memory in kB) of the primary.
start_replica() { # image memory-kb slot
	docker rm -f -v "$REPLICA" >/dev/null 2>&1
	docker run -d --name "$REPLICA" --network "$NET" \
		-e MAX_CPU=2 -e MAX_MEMORY="$2" -e MAX_CONNECTIONS=100 \
		-e COPY_ENDPOINT="$PRIMARY" -e REPLICATION_SLOT_NAME="$3" \
		-e POSTGRES_REPLICATOR_USER=replicator -e POSTGRES_REPLICATOR_PASSWORD="$REPLICATOR_PASSWORD" \
		"$1" >/dev/null
}

cleanup
docker network create "$NET" >/dev/null || exit 2
echo "== $IMAGE against a primary from $PRIMARY_IMAGE"

# A primary sized from 16 CPUs, 2 GB and 400 connections, with twice the replicas' share of WAL
# senders (10% of connections against 5%). Its first boot keeps PostgreSQL's own pg_hba.conf,
# which has no replication rule for other hosts, so the test adds one.
docker run -d --name "$PRIMARY" --network "$NET" -e MAX_CPU=16 -e MAX_MEMORY=2097152 -e MAX_CONNECTIONS=400 -e MAX_WAL_SENDERS_CONN_PERC=10 \
	-e POSTGRES_REPLICATOR_USER=replicator -e POSTGRES_REPLICATOR_PASSWORD="$REPLICATOR_PASSWORD" \
	"$PRIMARY_IMAGE" >/dev/null || exit 2
wait_ready "$PRIMARY" || { echo "primary did not start"; docker logs "$PRIMARY" 2>&1 | tail -5; exit 2; }
# psql_configure creates the replication user in the background, after the server accepts
# connections: a replica started before that fails its base backup.
# shellcheck disable=SC2034  # iteration only counts the retries
for iteration in $(seq 60); do [ "$(sql "$PRIMARY" "SELECT count(*) FROM pg_roles WHERE rolname = 'replicator'")" = 1 ] && break; sleep 2; done
[ "$(sql "$PRIMARY" "SELECT count(*) FROM pg_roles WHERE rolname = 'replicator'")" = 1 ] || { echo "the primary did not create the replication user"; exit 2; }
docker exec "$PRIMARY" sh -c 'echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"' || exit 2
sql "$PRIMARY" "SELECT pg_reload_conf()" >/dev/null
sql "$PRIMARY" "CREATE TABLE replica_test_marker(v text); INSERT INTO replica_test_marker VALUES ('replicated');" >/dev/null
PRIMARY_CONNECTIONS=$(setting "$PRIMARY" max_connections)
PRIMARY_WORKERS=$(setting "$PRIMARY" max_worker_processes)
PRIMARY_LOCKS=$(setting "$PRIMARY" max_locks_per_transaction)
PRIMARY_SENDERS=$(setting "$PRIMARY" max_wal_senders)
echo "primary: max_connections=$PRIMARY_CONNECTIONS max_worker_processes=$PRIMARY_WORKERS max_locks_per_transaction=$PRIMARY_LOCKS max_wal_senders=$PRIMARY_SENDERS"
if [ "$PRIMARY_CONNECTIONS" -gt 100 ] && [ "$PRIMARY_WORKERS" -gt 10 ] && [ "$PRIMARY_SENDERS" -gt 20 ]; then ok "the primary is sized larger than the replicas"; else bad "the primary is sized larger than the replicas"; fi

# 1. Before this change, a small replica refuses to start.
if [ -n "$IMAGE_BEFORE" ]; then
	start_replica "$IMAGE_BEFORE" 786432 replica_before
	wait_stopped "$REPLICA"
	if docker logs "$REPLICA" 2>&1 | grep -q "insufficient parameter settings"; then ok "before: a replica smaller than its primary does not start"; else bad "before: a replica smaller than its primary does not start"; fi
fi

# 2. A small replica starts as a standby with the primary's values.
start_replica "$IMAGE" 786432 replica_small
if wait_ready "$REPLICA" && [ "$(sql "$REPLICA" "SELECT pg_is_in_recovery()")" = t ]; then ok "a replica smaller than its primary starts as a standby"; else bad "a replica smaller than its primary starts as a standby"; docker logs "$REPLICA" 2>&1 | tail -5 | sed 's/^/    log: /'; fi
REPLICA_CONNECTIONS=$(setting "$REPLICA" max_connections)
REPLICA_WORKERS=$(setting "$REPLICA" max_worker_processes)
REPLICA_LOCKS=$(setting "$REPLICA" max_locks_per_transaction)
REPLICA_SENDERS=$(setting "$REPLICA" max_wal_senders)
if docker logs "$REPLICA" 2>&1 | grep -q "Reserving [0-9]* MB more for the lock rows"; then ok "the extra workers' lock rows are budgeted before tuning"; else bad "the extra workers' lock rows are budgeted before tuning"; fi
if [ "${REPLICA_CONNECTIONS:-0}" -ge "$PRIMARY_CONNECTIONS" ] && [ "${REPLICA_WORKERS:-0}" -ge "$PRIMARY_WORKERS" ] && [ "${REPLICA_LOCKS:-0}" -ge "$PRIMARY_LOCKS" ] && [ "${REPLICA_SENDERS:-0}" -ge "$PRIMARY_SENDERS" ]; then ok "its settings are raised to the primary's ($REPLICA_CONNECTIONS/$REPLICA_WORKERS/$REPLICA_LOCKS/$REPLICA_SENDERS)"; else bad "its settings are raised to the primary's (got ${REPLICA_CONNECTIONS:-?}/${REPLICA_WORKERS:-?}/${REPLICA_LOCKS:-?}/${REPLICA_SENDERS:-?})"; fi

# 3. Data replicates.
sql "$PRIMARY" "INSERT INTO replica_test_marker VALUES ('streamed');" >/dev/null
# shellcheck disable=SC2034  # iteration only counts the retries
for iteration in $(seq 15); do [ "$(sql "$REPLICA" "SELECT count(*) FROM replica_test_marker")" = 2 ] && break; sleep 1; done
if [ "$(sql "$REPLICA" "SELECT string_agg(v, ',' ORDER BY v) FROM replica_test_marker")" = "replicated,streamed" ]; then ok "the base backup and later writes reach the replica"; else bad "the base backup and later writes reach the replica"; fi

# 4. A restart keeps the raised settings (pg_control still holds the primary's values).
docker restart -t 20 "$REPLICA" >/dev/null
if wait_ready "$REPLICA" && [ "$(setting "$REPLICA" max_worker_processes)" = "$REPLICA_WORKERS" ] && [ "$(sql "$REPLICA" "SELECT pg_is_in_recovery()")" = t ]; then ok "after a restart the replica is still a standby with the primary's values"; else bad "after a restart the replica is still a standby with the primary's values"; fi

# 5. The primary raises max_prepared_transactions while the replica runs (the replica's
# postgresql.conf came with its base backup and still says 0). The replica replays the change into
# its pg_control; after a restart it must take the primary's value, or it would not start.
sql "$PRIMARY" "ALTER SYSTEM SET max_prepared_transactions = 20" >/dev/null
docker restart -t 20 "$PRIMARY" >/dev/null
wait_ready "$PRIMARY"
# shellcheck disable=SC2034  # iteration only counts the retries
for iteration in $(seq 60); do docker exec "$REPLICA" sh -c 'LC_ALL=C pg_controldata "$PGDATA"' 2>/dev/null | grep -q "max_prepared_xacts setting: *20" && break; sleep 2; done
docker restart -t 20 "$REPLICA" >/dev/null
if wait_ready "$REPLICA" && [ "$(sql "$REPLICA" "SELECT pg_is_in_recovery()")" = t ] && [ "$(setting "$REPLICA" max_prepared_transactions)" = 20 ]; then ok "a primary that raises max_prepared_transactions later is followed after a restart"; else bad "a primary that raises max_prepared_transactions later is followed after a restart"; docker logs "$REPLICA" 2>&1 | grep -E "FATAL|insufficient|Raising" | tail -3 | sed 's/^/    log: /'; fi

# 6. Once promoted, it is tuned from its own size again.
sql "$REPLICA" "SELECT pg_promote()" >/dev/null
# shellcheck disable=SC2034  # iteration only counts the retries
for iteration in $(seq 15); do [ "$(sql "$REPLICA" "SELECT pg_is_in_recovery()")" = f ] && break; sleep 1; done
docker restart -t 20 "$REPLICA" >/dev/null
if wait_ready "$REPLICA" && [ "$(sql "$REPLICA" "SELECT pg_is_in_recovery()")" = f ] && [ "$(setting "$REPLICA" max_connections)" = 100 ]; then ok "a promoted replica restarts tuned from its own size"; else bad "a promoted replica restarts tuned from its own size (max_connections=$(setting "$REPLICA" max_connections))"; fi

# 7. A replica where the extra slots' lock rows would eat into the reserve the tuner keeps free
# stops, instead of starting with no headroom and being killed by the kernel later.
start_replica "$IMAGE" 524288 replica_tight
wait_stopped "$REPLICA"
if [ "$(docker inspect -f '{{.State.ExitCode}}' "$REPLICA")" = 1 ] && docker logs "$REPLICA" 2>&1 | grep -q "Not enough memory: max_locks_per_transaction=$PRIMARY_LOCKS.*kept free"; then ok "a replica whose reserve the extra workers would eat stops and says why"; else bad "a replica whose reserve the extra workers would eat stops and says why"; fi

# 8. A replica whose memory cannot hold the primary's lock table stops with the sizes.
start_replica "$IMAGE" 262144 replica_tiny
wait_stopped "$REPLICA"
if [ "$(docker inspect -f '{{.State.ExitCode}}' "$REPLICA")" = 1 ] && docker logs "$REPLICA" 2>&1 | grep -q "Not enough memory: max_locks_per_transaction=$PRIMARY_LOCKS"; then ok "a replica too small for the lock table stops and says why"; else bad "a replica too small for the lock table stops and says why"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
