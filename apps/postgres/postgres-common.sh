#!/bin/sh
# Shared definitions for the postgres app. Sourced, never executed.
#
# Layout on the node:
#   /var/lib/orc-postgres/primary   durable root; the writer keeps its cluster in
#                                   primary/pgdata. The only directory worth backing up.
#   /var/lib/orc-postgres/replica   a replica's cluster, in replica/standby/pgdata. It sits
#                                   on the same App-data volume as the durable root (it can
#                                   be as large as the writer's), but standby/ is never
#                                   captured: a replica's copy is the writer's data.
#   /var/lib/orc-postgres/tls       the postgres account's copies of the certificates and
#                                   keys the server uses, re-staged on every start.
#   /var/lib/orc-postgres/state     node-local facts that must never travel with the data
#                                   to another machine: the last peers list, the marker
#                                   that this machine opened the writer's cluster, the
#                                   recovery and parked states, the empty stand-in.

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
# The overrides exist for running several nodes on one machine by hand (tests); a
# deployment never sets them.
PG_PORT=${PG_PORT:-5432}
PG_OS_USER=${PG_OS_USER:-postgres}
PG_SOCKET_DIR=${PG_SOCKET_DIR:-/var/run/postgresql}

APP_ROOT=${APP_ROOT:-/var/lib/orc-postgres}
PRIMARY_ROOT="$APP_ROOT/primary"
PRIMARY_PGDATA="$PRIMARY_ROOT/pgdata"
REPLICA_ROOT="$APP_ROOT/replica"
# standby/ is excluded from capture by the manifest's `!standby/**` filter.
REPLICA_LOCAL="$REPLICA_ROOT/standby"
REPLICA_PGDATA="$REPLICA_LOCAL/pgdata"
TLS_DIR="$APP_ROOT/tls"
# Node-local state: on this machine's own disk, outside every persisted root, so a
# restore onto a new machine does not bring it along.
STATE_DIR="$APP_ROOT/state"
PEERS_CACHE="$STATE_DIR/peers"
# This machine opened the writer's cluster; holds the cluster's system identifier.
WRITER_OPEN="$STATE_DIR/writer-open"
# Node 1 is deciding or copying; the capture hook refuses while it exists.
RECOVERING="$STATE_DIR/recovering"
# This replica holds data node 1 does not; holds the reason.
PARKED="$STATE_DIR/parked"
# This node holds no cluster and runs the stand-in that answers "empty".
STANDIN_DIR="$STATE_DIR/standin"
STANDIN_MARK="orc-postgres-empty"
# One-shot operator files.
FORCE_START="$APP_ROOT/force-start"
RELEASE_PARKED="$APP_ROOT/release-parked"

# Every DB role and map name the recipe owns. The replication role has no password: it
# is reachable only by presenting a client certificate the configured CA issued.
REPLICATION_ROLE=replicator
IDENT_MAP=certmap

# Which node is the writer. A deployment tells its nodes apart by SLOT, a 1-based
# number that is stable for the life of a node; node 1 is the writer and every other
# node streams from it. A single node has no one to tell apart, so SLOT defaults to 1
# and that node is the writer.
PG_SLOT=${SLOT:-1}
CLUSTER_NAME=${POOL:-postgres}

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
	if [ "$(id -u)" -eq "$(id -u "$PG_OS_USER")" ]; then
		env PATH="$PG_BIN:/usr/bin:/bin" "$@"
		return
	fi
	setpriv --reuid="$PG_OS_USER" --regid="$PG_OS_USER" --init-groups \
		env HOME=/var/lib/postgresql PATH="$PG_BIN:/usr/bin:/bin" "$@"
}

# A host name with an optional :port, as WRITER and the peers list carry them; split into
# PEER_HOST and PEER_PORT. Only hand-run nodes sharing one machine add a port.
pg_split_host() {
	case "$1" in
	*:*)
		PEER_HOST=${1%:*}
		PEER_PORT=${1##*:}
		;;
	*)
		PEER_HOST=$1
		PEER_PORT=$PG_PORT
		;;
	esac
}

# Whether a postmaster is running on the given data directory.
pg_running() {
	pg_as_postgres "$PG_BIN/pg_ctl" status -D "$1" >/dev/null 2>&1
}

pg_is_writer() {
	[ "$PG_SLOT" = "1" ]
}
