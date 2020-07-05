#!/bin/sh

# Default script behavior.
set -o errexit

# Default parameters.
DEBUG=true
DEBUG_OPT=

# Enables interruption signal handling.
trap - INT TERM

# Configures database
./psql_configure.sh &

# Executes the init command.
exec $@