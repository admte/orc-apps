#!/bin/sh
set -eu

# Start phase, resolved by name for the runtime-managed `postgres` service. The node
# owns the service definition; this script prepares the cluster for the slot this node
# holds and ends by exec'ing the postmaster under the postgres account, so PostgreSQL
# is the service's own process and the stop signal (SIGINT, fast shutdown) reaches it.
#
# Slot 1 is the writer: its cluster lives in the persisted root, is initialized on the
# first start, and carries the application role and database, which are reconciled
# on every start so an edited password or max_connections lands on restart. Every
# other slot is a streaming replica: its cluster is rebuilt from the writer with
# pg_basebackup on every start and lives outside the persisted root, so a replica's
# capture holds nothing.
#
# Authentication: the postgres superuser has no password and is reachable over the Unix
# socket alone (peer). The application role uses scram over TLS. Replication is cert
# authenticated: a replica presents the platform-issued client certificate, and the
# writer maps that certificate's subject onto the replication role, so no replication
# secret is shared across the pool. Plain TCP is refused everywhere (hostssl only).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_PHASE=start
# shellcheck source=postgres-common.sh
. "$SCRIPT_DIR/postgres-common.sh"

BOOTSTRAP_LOG=/var/log/postgresql/orc-bootstrap.log
# How long a replica keeps trying to seed from the writer before it gives up and lets
# the service manager restart it. The writer's name answers empty while no slot-1
# member is online, so a replica started ahead of its writer simply waits here.
SEED_TIMEOUT=${SEED_TIMEOUT:-1800}
SEED_INTERVAL=${SEED_INTERVAL:-10}

[ "$(id -u)" -eq 0 ] || pg_fail "must run as root"
pg_need setpriv
[ -x "$PG_BIN/postgres" ] || pg_fail "no install found; install must run first bin=$PG_BIN"
id "$PG_OS_USER" >/dev/null 2>&1 || pg_fail "the $PG_OS_USER account is missing"

[ -n "${SLOT:-}" ] || pg_fail "SLOT is required (pool.slot)"
case "$SLOT" in
'' | *[!0-9]*) pg_fail "SLOT must be a decimal slot number, got '$SLOT'" ;;
esac
[ "$SLOT" -ge 1 ] || pg_fail "SLOT must be 1 or higher, got '$SLOT'"

APP_USER=${APP_USER:-app}
APP_DB=${APP_DB:-app}
MAX_CONNECTIONS=${MAX_CONNECTIONS:-100}
case "$MAX_CONNECTIONS" in
'' | *[!0-9]*) pg_fail "MAX_CONNECTIONS must be a positive integer, got '$MAX_CONNECTIONS'" ;;
esac
[ "$MAX_CONNECTIONS" -ge 1 ] || pg_fail "MAX_CONNECTIONS must be a positive integer, got '$MAX_CONNECTIONS'"
CLUSTER_NAME=${POOL:-postgres}

# The application password, from the sensitive param's file. Read here, before the
# exec: the file is withdrawn once the app has started.
app_password() {
	[ -n "${PASSWORD_FILE:-}" ] || pg_fail "PASSWORD_FILE is required (the password param)"
	[ -r "$PASSWORD_FILE" ] || pg_fail "PASSWORD_FILE is not readable"
	tr -d '\r\n' <"$PASSWORD_FILE"
}

# Copies one platform-delivered PEM into the postgres account's TLS directory. The
# runtime's own materialization is 0600 in a 0700 directory owned by the account the
# runtime runs as, which the postmaster (running as postgres) cannot read; PostgreSQL
# also insists the server key be owned by the database user or root and be 0600.
# Re-staged on every start: the platform's certificates are short-lived and a renewal
# reaches this app as a restart.
stage_pem() {
	var=$1
	dest="$TLS_DIR/$2"
	eval "src=\${$var:-}"
	if [ -z "$src" ] || [ ! -s "$src" ]; then
		if [ "$3" = required ]; then
			pg_fail "$var is required and must name a non-empty file"
		fi
		rm -f "$dest"
		return 0
	fi
	cat "$src" >"$dest"
	chmod 0600 "$dest"
	chown "$PG_OS_USER:$PG_OS_USER" "$dest"
}

stage_tls() {
	mkdir -p "$TLS_DIR"
	chown "$PG_OS_USER:$PG_OS_USER" "$TLS_DIR"
	chmod 0700 "$TLS_DIR"
	stage_pem CA_FILE ca.pem required
	stage_pem SERVER_CERT_FILE server.crt required
	stage_pem SERVER_KEY_FILE server.key required
	# Only a replica dials the writer, so the client identity is optional on slot 1.
	if pg_is_writer; then
		stage_pem CLIENT_CERT_FILE client.crt optional
		stage_pem CLIENT_KEY_FILE client.key optional
	else
		stage_pem CLIENT_CERT_FILE client.crt required
		stage_pem CLIENT_KEY_FILE client.key required
	fi
	pg_note "staged the TLS material dir=$TLS_DIR"
}

# The settings this app owns, written to an include directory so the files initdb (or
# pg_basebackup) produced stay untouched, and regenerated on every start. A replica
# reads the same file; its standby role comes from standby.signal and the
# primary_conninfo pg_basebackup -R wrote into postgresql.auto.conf, which is read
# after this directory and so is never overridden here.
write_config() {
	pgdata=$1
	conf_dir="$pgdata/conf.d"
	mkdir -p "$conf_dir"
	if ! grep -q "^include_dir = 'conf.d'" "$pgdata/postgresql.conf"; then
		printf "\n# Settings managed by the orc postgres app.\ninclude_dir = 'conf.d'\n" >>"$pgdata/postgresql.conf"
	fi
	cat >"$conf_dir/orc.conf" <<CONF
# Written by the orc postgres app on every start. Edits here are lost on restart.
listen_addresses = '*'
port = $PG_PORT
unix_socket_directories = '$PG_SOCKET_DIR'
max_connections = $MAX_CONNECTIONS
cluster_name = '$CLUSTER_NAME'

ssl = on
ssl_cert_file = '$TLS_DIR/server.crt'
ssl_key_file = '$TLS_DIR/server.key'
ssl_ca_file = '$TLS_DIR/ca.pem'
ssl_min_protocol_version = 'TLSv1.2'
password_encryption = scram-sha-256

# Streaming replication to the other slots. WAL is kept by size rather than by
# replication slot: a replica rebuilds itself from scratch on every start anyway, and
# a slot left behind by a dead replica would fill the writer's disk.
wal_level = replica
max_wal_senders = 16
wal_keep_size = '1GB'
hot_standby = on

# Logs go to the service's stderr, where the platform collects them.
log_destination = 'stderr'
logging_collector = off
log_line_prefix = '%m [%p] %q%u@%d '
CONF
	# Order matters: the first matching line decides. The superuser and the
	# replication role are refused over the network before the general rules, so
	# neither can be reached with a password even if one were ever set.
	cat >"$pgdata/pg_hba.conf" <<HBA
# Written by the orc postgres app on every start. Edits here are lost on restart.
# TYPE     DATABASE      USER                ADDRESS   METHOD
local      all           $PG_OS_USER            peer
hostssl    all           $PG_OS_USER         all       reject
hostssl    all           $REPLICATION_ROLE   all       reject
hostssl    replication   $REPLICATION_ROLE   all       cert map=$IDENT_MAP
hostssl    all           all                 all       scram-sha-256
HBA
	# The platform issues every client certificate with the same subject; what
	# makes it a replication credential is that only the project's CA can issue it.
	cat >"$pgdata/pg_ident.conf" <<IDENT
# Written by the orc postgres app on every start. Edits here are lost on restart.
# MAPNAME      SYSTEM-USERNAME       PG-USERNAME
$IDENT_MAP     "ORC mTLS client"     $REPLICATION_ROLE
IDENT
	chown -R "$PG_OS_USER:$PG_OS_USER" "$conf_dir" "$pgdata/postgresql.conf" "$pgdata/pg_hba.conf" "$pgdata/pg_ident.conf"
	chmod 0600 "$pgdata/pg_hba.conf" "$pgdata/pg_ident.conf"
}

# Creates or repairs the writer's cluster in the persisted root, then reconciles the
# roles and the database over the Unix socket on a postmaster started for that purpose
# alone (no TCP listener), which is stopped again before the real one is exec'd.
start_primary() {
	pgdata=$PRIMARY_PGDATA
	pg_note "slot 1: this node is the writer persist_state=${APP_PERSIST_STATE:-unset} pgdata=$pgdata"
	password=$(app_password)
	[ -n "$password" ] || pg_fail "the application password is empty"

	mkdir -p "$PRIMARY_ROOT"
	chown "$PG_OS_USER:$PG_OS_USER" "$PRIMARY_ROOT"
	chmod 0700 "$PRIMARY_ROOT"

	if [ -s "$pgdata/PG_VERSION" ]; then
		have=$(tr -d '\r\n' <"$pgdata/PG_VERSION")
		[ "$have" = "$PG_MAJOR" ] || pg_fail "the persisted cluster is PostgreSQL $have; this app runs $PG_MAJOR and does not upgrade in place"
		# A restored or crash-stopped cluster may carry a pid file from a postmaster
		# that no longer exists. Only a file no running server accounts for is removed.
		if [ -e "$pgdata/postmaster.pid" ] && ! pg_running "$pgdata"; then
			pg_note "removing a stale postmaster.pid"
			rm -f "$pgdata/postmaster.pid"
		fi
		if [ "$(stat -c %U "$pgdata")" != "$PG_OS_USER" ]; then
			pg_note "taking ownership of the persisted cluster for $PG_OS_USER"
			chown -R "$PG_OS_USER:$PG_OS_USER" "$pgdata"
		fi
		chmod 0700 "$pgdata"
		pg_note "using the existing cluster"
	else
		if [ -d "$pgdata" ] && [ -n "$(ls -A "$pgdata")" ]; then
			pg_fail "$pgdata holds files but no PostgreSQL cluster; refusing to initialize over them"
		fi
		mkdir -p "$pgdata"
		chown "$PG_OS_USER:$PG_OS_USER" "$pgdata"
		chmod 0700 "$pgdata"
		pg_note "initializing a new cluster"
		# No --pwfile: the superuser gets no password, on purpose. Host access is
		# closed until pg_hba.conf is written below.
		pg_as_postgres "$PG_BIN/initdb" -D "$pgdata" \
			--auth-local=peer --auth-host=reject \
			--encoding=UTF8 --locale=C.UTF-8 --data-checksums >&2
	fi

	write_config "$pgdata"
	reconcile_roles "$pgdata" "$password"
	password=""

	pg_note "starting the writer"
	exec_postgres "$pgdata"
}

# Roles and the database, reconciled on a socket-only postmaster. psql variables
# carry the names: `:'name'` interpolates a properly quoted literal and format(%I)
# turns it into an identifier server-side, so no value is spliced into SQL by the
# shell. The password never touches argv: psql reads it from a file only the postgres
# account can open, which is removed again before the real postmaster starts.
reconcile_roles() {
	pgdata=$1
	password=$2
	password_file="$TLS_DIR/app.password"
	mkdir -p "$(dirname "$BOOTSTRAP_LOG")"
	: >"$BOOTSTRAP_LOG"
	chown "$PG_OS_USER:$PG_OS_USER" "$BOOTSTRAP_LOG"
	(
		umask 077
		printf '%s' "$password" >"$password_file"
	)
	chown "$PG_OS_USER:$PG_OS_USER" "$password_file"
	pg_note "reconciling roles and the database over the socket"
	if ! pg_as_postgres "$PG_BIN/pg_ctl" start -w -t 300 -s -D "$pgdata" -l "$BOOTSTRAP_LOG" \
		-o "-c listen_addresses='' -c unix_socket_directories='$PG_SOCKET_DIR'"; then
		rm -f "$password_file"
		cat "$BOOTSTRAP_LOG" >&2
		pg_fail "the cluster did not start for role reconciliation"
	fi
	status=0
	pg_as_postgres "$PG_BIN/psql" -X -q -w -v ON_ERROR_STOP=1 \
		-h "$PG_SOCKET_DIR" -p "$PG_PORT" -d postgres \
		-v replicator="$REPLICATION_ROLE" -v app_user="$APP_USER" -v app_db="$APP_DB" \
		-v password_file="$password_file" \
		>/dev/null <<'SQL' || status=$?
\set pw `cat :'password_file'`
SELECT format('CREATE ROLE %I WITH REPLICATION LOGIN', :'replicator')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'replicator')
\gexec
SELECT format('CREATE ROLE %I WITH LOGIN', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
\gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'pw')
\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db')
\gexec
SQL
	rm -f "$password_file"
	pg_as_postgres "$PG_BIN/pg_ctl" stop -w -t 300 -s -m fast -D "$pgdata" || {
		cat "$BOOTSTRAP_LOG" >&2
		pg_fail "the reconciliation postmaster did not stop"
	}
	if [ "$status" -ne 0 ]; then
		cat "$BOOTSTRAP_LOG" >&2
		pg_fail "role reconciliation failed (psql exit $status)"
	fi
	pg_note "roles reconciled role=$APP_USER db=$APP_DB replication_role=$REPLICATION_ROLE"
}

# Rebuilds this replica from the writer and follows it. The old copy is discarded
# first: a replica's data is a copy of slot 1, so nothing in it is worth keeping, and
# a fresh base backup is the one seed that is always consistent with the writer.
start_replica() {
	pgdata=$REPLICA_PGDATA
	[ -n "${WRITER:-}" ] || pg_fail "WRITER is required (peers.first) on slot $SLOT"
	pg_note "slot $SLOT: this node is a replica of $WRITER pgdata=$pgdata"

	rm -rf "$pgdata"
	mkdir -p "$pgdata"
	chown "$PG_OS_USER:$PG_OS_USER" "$(dirname "$pgdata")" "$pgdata"
	chmod 0700 "$(dirname "$pgdata")" "$pgdata"

	# verify-full against the project chain: the writer's certificate carries its
	# slot name, which is exactly the name peers.first resolved to.
	conninfo="host=$WRITER port=$PG_PORT user=$REPLICATION_ROLE"
	conninfo="$conninfo sslmode=verify-full sslrootcert=$TLS_DIR/ca.pem"
	conninfo="$conninfo sslcert=$TLS_DIR/client.crt sslkey=$TLS_DIR/client.key"
	conninfo="$conninfo application_name=$CLUSTER_NAME-$SLOT"

	deadline=$(($(date +%s) + SEED_TIMEOUT))
	attempt=0
	until pg_as_postgres "$PG_BIN/pg_basebackup" -D "$pgdata" -R -X stream --checkpoint=fast \
		--no-password -d "$conninfo" 2>>"$APP_ROOT/replica/seed.log"; do
		attempt=$((attempt + 1))
		# A failed attempt may leave a partial copy behind.
		find "$pgdata" -mindepth 1 -delete
		if [ "$(date +%s)" -ge "$deadline" ]; then
			tail -n 20 "$APP_ROOT/replica/seed.log" >&2
			pg_fail "could not seed from $WRITER within ${SEED_TIMEOUT}s"
		fi
		pg_note "seed attempt $attempt failed; the writer may not be up yet, retrying in ${SEED_INTERVAL}s: $(tail -n 1 "$APP_ROOT/replica/seed.log")"
		sleep "$SEED_INTERVAL"
	done
	rm -f "$APP_ROOT/replica/seed.log"
	pg_note "seeded from $WRITER"

	write_config "$pgdata"
	pg_note "starting the replica"
	exec_postgres "$pgdata"
}

exec_postgres() {
	exec setpriv --reuid="$PG_OS_USER" --regid="$PG_OS_USER" --init-groups \
		env HOME=/var/lib/postgresql PATH="$PG_BIN:/usr/bin:/bin" \
		"$PG_BIN/postgres" -D "$1"
}

stage_tls
if pg_is_writer; then
	start_primary
else
	start_replica
fi
