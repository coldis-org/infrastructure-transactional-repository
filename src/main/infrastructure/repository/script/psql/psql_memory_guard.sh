#!/bin/sh

# Memory guard: watches the container's memory and ends the sessions holding the most private
# memory before the kernel has to kill anything (see psql_memory.sh). Started in the background
# by psql_init.sh and psql_replica_init.sh, as the postgres user; runs for as long as the
# container. Never exits with anything but 0 (see memory_guard_main).

. "$(dirname "$0")/psql_memory.sh"
memory_guard_main
exit 0
