#!/bin/sh

# Migrates the data of a previous deployment and then starts the database, so that a
# migration is a deployment of this image in place of the repository one, and nothing else.

# Default script behavior.
set -o errexit

# Enables interruption signal handling.
trap - INT TERM

# Migrates the data of a previous deployment, if there is any to migrate.
./psql_upgrade.sh

# Hands off to the regular initialization, which starts the database. The arguments are the
# ones of the repository image, so the tuned command line is built the same way.
exec ./psql_init.sh "$@"
