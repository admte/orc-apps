#!/bin/sh
set -eu

# Start phase. Prepares this node's cluster and ends by exec'ing the postmaster under
# the postgres account, so PostgreSQL is the service's own process and the stop signal
# (SIGINT, fast shutdown) reaches it directly.
#
# One node or many, the rule is the same: the node holding slot 1 is the writer, keeps
# its cluster in the durable root, and owns the application role and database. Every
# other node is a streaming replica that rebuilds itself from the writer on each start
# and keeps its copy outside the durable root, so only the writer's data is worth
# capturing. With no SLOT set there is nothing to tell apart, so the node is slot 1 and
# runs alone.
#
# Authentication: the postgres superuser has no password and is reachable over the Unix
# socket alone. The application role uses SCRAM, and TLS is always on -- a server
# certificate is generated on first start when none is supplied. Replication is
# authenticated by certificate: a replica presents a client certificate, and the writer
# accepts it if the configured CA issued it, so no replication secret is shared.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_PHASE=start
# shellcheck source=postgres-common.sh
. "$SCRIPT_DIR/postgres-common.sh"

# The reconciliation postmaster's log, in the app's own root rather than the distro's
# /var/log/postgresql, which belongs to the package and may not exist.
BOOTSTRAP_LOG="$APP_ROOT/bootstrap.log"
# How long a replica keeps trying to seed from the writer before giving up and letting
# the service manager restart it. A replica started before its writer simply waits here.
SEED_TIMEOUT=${SEED_TIMEOUT:-1800}
SEED_INTERVAL=${SEED_INTERVAL:-10}
# Set by stage_tls: whether a CA was supplied, which is what makes certificate
# authentication -- and therefore replication -- possible.
PG_HAVE_CA=no

[ "$(id -u)" -eq 0 ] || pg_fail "must run as root"
pg_need setpriv
[ -x "$PG_BIN/postgres" ] || pg_fail "no install found; install must run first bin=$PG_BIN"
id "$PG_OS_USER" >/dev/null 2>&1 || pg_fail "the $PG_OS_USER account is missing"

case "$PG_SLOT" in
'' | *[!0-9]*) pg_fail "SLOT must be a whole number, got '$PG_SLOT'" ;;
esac
[ "$PG_SLOT" -ge 1 ] || pg_fail "SLOT must be 1 or higher, got '$PG_SLOT'"

APP_USER=${APP_USER:-app}
APP_DB=${APP_DB:-app}
MAX_CONNECTIONS=${MAX_CONNECTIONS:-100}
case "$MAX_CONNECTIONS" in
'' | *[!0-9]*) pg_fail "MAX_CONNECTIONS must be a positive integer, got '$MAX_CONNECTIONS'" ;;
esac
[ "$MAX_CONNECTIONS" -ge 1 ] || pg_fail "MAX_CONNECTIONS must be a positive integer, got '$MAX_CONNECTIONS'"
CLUSTER_NAME=${POOL:-postgres}

# The application password, from the sensitive param's file, or empty when none was
# supplied this start. Read here, before the exec: the file may be withdrawn once the
# app has started, and a later service-manager restart then runs with it gone. An
# existing cluster already holds the role, so a start without it is not an error.
app_password() {
	if [ -z "${PASSWORD_FILE:-}" ] || [ ! -r "$PASSWORD_FILE" ]; then
		return 0
	fi
	tr -d '\r\n' <"$PASSWORD_FILE"
}

# Copies one supplied PEM into the postgres account's TLS directory, and reports
# whether there was one. A caller's own file is typically unreadable to the postgres
# account, and PostgreSQL insists the server key be owned by the database user and be
# 0600; re-staged on every start, because certificates are short-lived and a renewal
# reaches this app as a restart. Never deletes: what to do about a file that is no
# longer supplied differs per file, so that is the caller's call.
stage_pem() {
	dest="$TLS_DIR/$2"
	eval "src=\${$1:-}"
	if [ -z "$src" ] || [ ! -s "$src" ]; then
		return 1
	fi
	cat "$src" >"$dest"
	chmod 0600 "$dest"
	chown "$PG_OS_USER:$PG_OS_USER" "$dest"
	return 0
}

# Forgets a staged file that is no longer supplied, so a deployment that stops sending
# one is not left running on yesterday's copy.
drop_pem() {
	rm -f "$TLS_DIR/$1"
}

# A certificate for the listener when the deployment supplies none. Generated once and
# reused, so clients are not asked to trust a new key on every restart. Self-signed, so
# a client verifies nothing beyond the connection being encrypted (sslmode=require);
# supply server_cert, server_key and ca to get a verifiable one.
generate_server_cert() {
	pg_need openssl
	cn=$(hostname 2>/dev/null || echo postgres)
	pg_note "no server certificate supplied; generating a self-signed one cn=$cn"
	openssl req -new -x509 -days 3650 -nodes -subj "/CN=$cn" \
		-keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.crt" >/dev/null 2>&1 ||
		pg_fail "could not generate a self-signed server certificate"
	chmod 0600 "$TLS_DIR/server.key" "$TLS_DIR/server.crt"
	chown "$PG_OS_USER:$PG_OS_USER" "$TLS_DIR/server.key" "$TLS_DIR/server.crt"
	: >"$TLS_DIR/server.self-signed"
}

stage_tls() {
	mkdir -p "$TLS_DIR"
	chown "$PG_OS_USER:$PG_OS_USER" "$TLS_DIR"
	chmod 0700 "$TLS_DIR"

	if stage_pem CA_FILE ca.pem; then
		PG_HAVE_CA=yes
	else
		drop_pem ca.pem
	fi

	# A supplied pair replaces a generated one and vice versa, so switching either way
	# takes effect on the next start rather than leaving yesterday's certificate behind.
	if stage_pem SERVER_CERT_FILE server.crt && stage_pem SERVER_KEY_FILE server.key; then
		rm -f "$TLS_DIR/server.self-signed"
	elif [ -s "$TLS_DIR/server.crt" ] && [ -s "$TLS_DIR/server.key" ] &&
		[ -e "$TLS_DIR/server.self-signed" ]; then
		pg_note "reusing the generated server certificate"
	else
		generate_server_cert
	fi

	# Only a replica dials the writer, so the client identity is required on other nodes
	# and unused on the writer.
	if ! stage_pem CLIENT_CERT_FILE client.crt || ! stage_pem CLIENT_KEY_FILE client.key; then
		drop_pem client.crt
		drop_pem client.key
		if ! pg_is_writer; then
			pg_fail "node $PG_SLOT is a replica: it needs client_cert and client_key to authenticate to the writer"
		fi
	fi

	if ! pg_is_writer && [ "$PG_HAVE_CA" != yes ]; then
		pg_fail "node $PG_SLOT is a replica: it needs ca to verify the writer"
	fi
	pg_note "staged the TLS material dir=$TLS_DIR ca=$PG_HAVE_CA"
}

# The settings this app owns, written to an include directory so the files initdb (or
# pg_basebackup) produced stay untouched, and regenerated on every start. A replica
# reads the same file; its standby role comes from standby.signal and the
# primary_conninfo pg_basebackup -R wrote into postgresql.auto.conf, which is read after
# this directory and so is never overridden here.
write_config() {
	pgdata=$1
	conf_dir="$pgdata/conf.d"
	mkdir -p "$conf_dir"
	if ! grep -q "^include_dir = 'conf.d'" "$pgdata/postgresql.conf"; then
		printf "\n# Settings managed by the postgres app.\ninclude_dir = 'conf.d'\n" >>"$pgdata/postgresql.conf"
	fi
	cat >"$conf_dir/orc.conf" <<CONF
# Written by the postgres app on every start. Edits here are lost on restart.
listen_addresses = '*'
port = $PG_PORT
unix_socket_directories = '$PG_SOCKET_DIR'
max_connections = $MAX_CONNECTIONS
cluster_name = '$CLUSTER_NAME'

ssl = on
ssl_cert_file = '$TLS_DIR/server.crt'
ssl_key_file = '$TLS_DIR/server.key'
ssl_min_protocol_version = 'TLSv1.2'
password_encryption = scram-sha-256

# Streaming replication to the other nodes. WAL is kept by size rather than by
# replication slot: a replica rebuilds itself from scratch on every start anyway, and a
# slot left behind by a dead replica would fill the writer's disk.
wal_level = replica
max_wal_senders = 16
wal_keep_size = '1GB'
hot_standby = on

# Logs go to the service's stderr, where the supervisor collects them.
log_destination = 'stderr'
logging_collector = off
log_line_prefix = '%m [%p] %q%u@%d '
CONF
	if [ "$PG_HAVE_CA" = yes ]; then
		echo "ssl_ca_file = '$TLS_DIR/ca.pem'" >>"$conf_dir/orc.conf"
	fi

	# Order matters: the first matching line decides. The superuser and the replication
	# role are refused over the network before the general rules, so neither can be
	# reached with a password even if one were ever set. Plain TCP is never matched, so
	# every network client speaks TLS.
	hba_line() {
		printf '%-10s %-13s %-20s %-9s %s\n' "$1" "$2" "$3" "$4" "$5" >>"$pgdata/pg_hba.conf"
	}
	cat >"$pgdata/pg_hba.conf" <<HBA
# Written by the postgres app on every start. Edits here are lost on restart.
HBA
	hba_line "# TYPE" DATABASE USER ADDRESS METHOD
	hba_line local all "$PG_OS_USER" "" peer
	hba_line local all "$REPLICATION_ROLE" "" reject
	hba_line local all all "" scram-sha-256
	hba_line hostssl all "$PG_OS_USER" all reject
	hba_line hostssl all "$REPLICATION_ROLE" all reject
	# Certificate authentication needs a CA to verify against, so replication is offered
	# only once one is configured. A lone writer has no replicas and needs no CA.
	if [ "$PG_HAVE_CA" = yes ]; then
		hba_line hostssl replication "$REPLICATION_ROLE" all "cert map=$IDENT_MAP"
	fi
	hba_line hostssl all all all scram-sha-256

	# Any client certificate the configured CA issued may replicate; which certificates
	# exist is the CA's business, not this file's. Scope the CA accordingly.
	{
		echo "# Written by the postgres app on every start. Edits here are lost on restart."
		printf '%-14s %-18s %s\n' "# MAPNAME" SYSTEM-USERNAME PG-USERNAME
		printf '%-14s %-18s %s\n' "$IDENT_MAP" '/^.*$' "$REPLICATION_ROLE"
	} >"$pgdata/pg_ident.conf"
	chown -R "$PG_OS_USER:$PG_OS_USER" "$conf_dir" "$pgdata/postgresql.conf" "$pgdata/pg_hba.conf" "$pgdata/pg_ident.conf"
	chmod 0600 "$pgdata/pg_hba.conf" "$pgdata/pg_ident.conf"
}

# Creates or repairs the writer's cluster in the durable root, then reconciles the roles
# and the database over the Unix socket on a postmaster started for that purpose alone
# (no TCP listener), which is stopped again before the real one is exec'd.
start_primary() {
	pgdata=$PRIMARY_PGDATA
	pg_note "node 1: this node is the writer pgdata=$pgdata"

	mkdir -p "$PRIMARY_ROOT"
	chown "$PG_OS_USER:$PG_OS_USER" "$PRIMARY_ROOT"
	chmod 0700 "$PRIMARY_ROOT"

	password=$(app_password)

	if [ -s "$pgdata/PG_VERSION" ]; then
		have=$(tr -d '\r\n' <"$pgdata/PG_VERSION")
		[ "$have" = "$PG_MAJOR" ] || pg_fail "the stored cluster is PostgreSQL $have; this app runs $PG_MAJOR and does not upgrade in place"
		# A restored or crash-stopped cluster may carry a pid file from a postmaster that
		# no longer exists. Only a file no running server accounts for is removed.
		if [ -e "$pgdata/postmaster.pid" ] && ! pg_running "$pgdata"; then
			pg_note "removing a stale postmaster.pid"
			rm -f "$pgdata/postmaster.pid"
		fi
		if [ "$(stat -c %U "$pgdata")" != "$PG_OS_USER" ]; then
			pg_note "taking ownership of the stored cluster for $PG_OS_USER"
			chown -R "$PG_OS_USER:$PG_OS_USER" "$pgdata"
		fi
		chmod 0700 "$pgdata"
		pg_note "using the existing cluster"
	else
		[ -n "$password" ] || pg_fail "a password is required to create the cluster; pass it as a file, e.g. --password=@/path/to/file"
		if [ -d "$pgdata" ] && [ -n "$(ls -A "$pgdata")" ]; then
			pg_fail "$pgdata holds files but no PostgreSQL cluster; refusing to initialize over them"
		fi
		mkdir -p "$pgdata"
		chown "$PG_OS_USER:$PG_OS_USER" "$pgdata"
		chmod 0700 "$pgdata"
		pg_note "initializing a new cluster"
		# No --pwfile: the superuser gets no password, on purpose. Host access is closed
		# until pg_hba.conf is written below.
		pg_as_postgres "$PG_BIN/initdb" -D "$pgdata" \
			--auth-local=peer --auth-host=reject \
			--encoding=UTF8 --locale=C.UTF-8 --data-checksums >&2
	fi

	write_config "$pgdata"
	if [ -n "$password" ]; then
		reconcile_roles "$pgdata" "$password"
		password=""
	else
		pg_note "no password supplied this start; leaving the existing roles as they are"
	fi

	pg_note "starting the writer"
	exec_postgres "$pgdata"
}

# Roles and the database, reconciled on a socket-only postmaster. psql variables carry
# the names: `:'name'` interpolates a properly quoted literal and format(%I) turns it
# into an identifier server-side, so no value is spliced into SQL by the shell. The
# password never touches argv: psql reads it from a file only the postgres account can
# open, which is removed again before the real postmaster starts.
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

# Rebuilds this replica from the writer and follows it. The old copy is discarded first:
# a replica's data is a copy of the writer, so nothing in it is worth keeping, and a
# fresh base backup is the one seed that is always consistent with the writer.
start_replica() {
	pgdata=$REPLICA_PGDATA
	[ -n "${WRITER:-}" ] || pg_fail "node $PG_SLOT is a replica: set WRITER to the host name of the writer (node 1)"
	pg_note "node $PG_SLOT: this node is a replica of $WRITER pgdata=$pgdata"

	rm -rf "$pgdata"
	mkdir -p "$pgdata"
	chown "$PG_OS_USER:$PG_OS_USER" "$(dirname "$pgdata")" "$pgdata"
	chmod 0700 "$(dirname "$pgdata")" "$pgdata"

	# verify-full: the writer's certificate has to be issued by the configured CA and
	# carry the name this replica dialed.
	conninfo="host=$WRITER port=$PG_PORT user=$REPLICATION_ROLE"
	conninfo="$conninfo sslmode=verify-full sslrootcert=$TLS_DIR/ca.pem"
	conninfo="$conninfo sslcert=$TLS_DIR/client.crt sslkey=$TLS_DIR/client.key"
	conninfo="$conninfo application_name=$CLUSTER_NAME-$PG_SLOT"

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
