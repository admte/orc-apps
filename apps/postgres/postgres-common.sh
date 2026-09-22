#!/bin/sh
# Shared definitions for the postgres app. Sourced, never executed.
#
# Layout on the node:
#   /var/lib/orc-postgres/primary   the durable root; the writer keeps its cluster in
#                                   primary/pgdata. This is the only directory worth
#                                   backing up, and the only one a deployment that
#                                   snapshots app data needs to capture.
#   /var/lib/orc-postgres/replica   a replica's cluster, rebuilt from the writer on every
#                                   start. Never worth capturing: it is a copy of the writer.
#   /var/lib/orc-postgres/tls       the postgres account's copies of the certificates and
#                                   keys the server uses, re-staged on every start.

# Which PostgreSQL to run. APP_VERSION carries the version the deployment selected and
# is set for every phase; the major alone decides the packages and the binary path, so
# "17" and "17.6" mean the same thing here. Unset means the default below, which is what
# a package installed without naming a version gets.
PG_DEFAULT_MAJOR=17
PG_MAJOR=${PG_MAJOR:-${APP_VERSION:-$PG_DEFAULT_MAJOR}}
PG_MAJOR=${PG_MAJOR%%.*}
case "$PG_MAJOR" in
'' | *[!0-9]*)
	echo "postgres: APP_VERSION must start with a major version number, got '${APP_VERSION:-}'" >&2
	exit 1
	;;
esac
PG_BIN=${PG_BIN:-/usr/lib/postgresql/$PG_MAJOR/bin}
PG_PORT=5432
PG_OS_USER=postgres
PG_SOCKET_DIR=/var/run/postgresql

APP_ROOT=${APP_ROOT:-/var/lib/orc-postgres}
PRIMARY_ROOT="$APP_ROOT/primary"
PRIMARY_PGDATA="$PRIMARY_ROOT/pgdata"
REPLICA_PGDATA="$APP_ROOT/replica/pgdata"
TLS_DIR="$APP_ROOT/tls"

# Every DB role and map name the recipe owns. The replication role has no password: it
# is reachable only by presenting a client certificate the configured CA issued.
REPLICATION_ROLE=replicator
IDENT_MAP=certmap

# Which node is the writer. A deployment tells its nodes apart by SLOT, a 1-based
# number that is stable for the life of a node; node 1 is the writer and every other
# node streams from it. A single node has no one to tell apart, so SLOT defaults to 1
# and that node is the writer.
PG_SLOT=${SLOT:-1}

pg_note() {
	echo "postgres $PG_PHASE: $*" >&2
}

pg_fail() {
	echo "postgres $PG_PHASE: $*" >&2
	exit 1
}

pg_need() {
	command -v "$1" >/dev/null 2>&1 || pg_fail "$1 is required"
}

# Runs a command as the postgres account inside the same session, so a server started
# this way stays the service's own process and the stop signal reaches it. setpriv,
# never su or runuser: those start a new session, where the signal no longer lands.
pg_as_postgres() {
	setpriv --reuid="$PG_OS_USER" --regid="$PG_OS_USER" --init-groups \
		env HOME=/var/lib/postgresql PATH="$PG_BIN:/usr/bin:/bin" "$@"
}

# Whether a postmaster is running on the given data directory.
pg_running() {
	pg_as_postgres "$PG_BIN/pg_ctl" status -D "$1" >/dev/null 2>&1
}

pg_is_writer() {
	[ "$PG_SLOT" = "1" ]
}
