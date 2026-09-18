#!/bin/sh
# Shared definitions for the postgres app. Sourced, never executed.
#
# Layout on the node:
#   /var/lib/orc-postgres/primary   the persisted root; slot 1 keeps its cluster in
#                                   primary/pgdata. Captured and restored by the platform.
#   /var/lib/orc-postgres/replica   a replica's cluster, rebuilt from the writer on every
#                                   start. Never captured: it is a copy of slot 1.
#   /var/lib/orc-postgres/tls       the postgres account's copies of the platform TLS
#                                   material, re-staged on every start.

PG_MAJOR=${PG_MAJOR:-17}
PG_BIN=${PG_BIN:-/usr/lib/postgresql/$PG_MAJOR/bin}
PG_PORT=5432
PG_OS_USER=postgres
PG_SOCKET_DIR=/var/run/postgresql

APP_ROOT=${APP_ROOT:-/var/lib/orc-postgres}
PRIMARY_ROOT="$APP_ROOT/primary"
PRIMARY_PGDATA="$PRIMARY_ROOT/pgdata"
REPLICA_PGDATA="$APP_ROOT/replica/pgdata"
TLS_DIR="$APP_ROOT/tls"

# Every DB role and map name the recipe owns. The replication role has no password:
# it is reachable only with a platform-issued client certificate.
REPLICATION_ROLE=replicator
IDENT_MAP=orc

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

# Runs a command as the postgres account inside the same session, so a server
# started this way stays the service's own process and the stop signal reaches it.
# setpriv, never su or runuser (spec: those detach the child into a new session).
pg_as_postgres() {
	setpriv --reuid="$PG_OS_USER" --regid="$PG_OS_USER" --init-groups \
		env HOME=/var/lib/postgresql PATH="$PG_BIN:/usr/bin:/bin" "$@"
}

# Whether a postmaster is running on the given data directory.
pg_running() {
	pg_as_postgres "$PG_BIN/pg_ctl" status -D "$1" >/dev/null 2>&1
}

# Whether the node holds slot 1, which is the writer by the platform's convention.
pg_is_writer() {
	[ "${SLOT:-}" = "1" ]
}
