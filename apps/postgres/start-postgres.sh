#!/bin/sh
set -eu

# Start phase. Prepares this node's cluster and ends by exec'ing the postmaster under
# the postgres account, so PostgreSQL is the service's own process and the stop signal
# (SIGINT, fast shutdown) reaches it directly.
#
# One node or many, the rule is the same: the node holding slot 1 is the writer, keeps
# its cluster in the durable root, and owns the application role and database. Every
# other node is a streaming replica of it. With no SLOT set there is nothing to tell
# apart, so the node is slot 1 and runs alone. How node 1 makes sure it holds the newest
# data before it takes writes, and why a replica never throws away data node 1 lacks, is
# "Recovery and durability" in README.md; this script is that contract.
#
# Authentication: the postgres superuser has no password and is reachable over the Unix
# socket alone. The application role uses SCRAM, and TLS is always on -- a server
# certificate is generated on first start when none is supplied. Replication is
# authenticated by certificate: a replica presents a client certificate, and the writer
# accepts it if the configured CA issued it, so no replication secret is shared.
#
# This script never exits non-zero for a reason that would recur. An orchestrator may
# replace a machine whose app keeps failing, and a replaced replica takes its data with
# it; so a start that cannot go on says why in the log and holds, and a restart (after
# the cause is fixed) tries again. While it holds or waits, nothing listens for clients.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_PHASE=start
# shellcheck source=postgres-common.sh
. "$SCRIPT_DIR/postgres-common.sh"
# shellcheck source=postgres-position.sh
. "$SCRIPT_DIR/postgres-position.sh"

pg_hold() {
	pg_warn "HOLD: $*"
	pg_warn "HOLD: this node stays down until the app is restarted"
	while :; do
		sleep 600
		pg_warn "HOLD: $*"
	done
}
pg_fail() {
	pg_hold "$@"
}

# The bootstrap postmaster's log, in the app's own root rather than the distro's
# /var/log/postgresql, which belongs to the package and may not exist.
BOOTSTRAP_LOG="$APP_ROOT/bootstrap.log"
SEED_INTERVAL=${SEED_INTERVAL:-10}
# Set by stage_tls: whether a CA was supplied, which is what makes certificate
# authentication -- and therefore replication -- possible.
PG_HAVE_CA=no
PG_HAVE_CLIENT=no

if [ "$(id -u)" -ne 0 ] && [ "$(id -un)" != "$PG_OS_USER" ]; then
	pg_fail "must run as root"
fi
[ "$(id -u)" -ne 0 ] || pg_need setpriv
[ -x "$PG_BIN/postgres" ] || pg_fail "no install found; install must run first bin=$PG_BIN"
id "$PG_OS_USER" >/dev/null 2>&1 || pg_fail "the $PG_OS_USER account is missing"

case "$PG_SLOT" in
'' | *[!0-9]*) pg_fail "SLOT must be a whole number, got '$PG_SLOT'" ;;
esac
[ "$PG_SLOT" -ge 1 ] || pg_fail "SLOT must be 1 or higher, got '$PG_SLOT'"

DB_USER=${DB_USER:-app}
DB_NAME=${DB_NAME:-app}
MAX_CONNECTIONS=${MAX_CONNECTIONS:-100}
case "$MAX_CONNECTIONS" in
'' | *[!0-9]*) pg_fail "MAX_CONNECTIONS must be a positive integer, got '$MAX_CONNECTIONS'" ;;
esac
[ "$MAX_CONNECTIONS" -ge 1 ] || pg_fail "MAX_CONNECTIONS must be a positive integer, got '$MAX_CONNECTIONS'"

# The application password, from the sensitive param's file, or empty when none was
# supplied this start. Read here, before the exec: the file may be withdrawn once the
# app has started, and a later service-manager restart then runs with it gone. An
# existing cluster already holds the role, so a start without it is not an error.
app_password() {
	if [ -z "${DB_PASSWORD_FILE:-}" ] || [ ! -r "$DB_PASSWORD_FILE" ]; then
		return 0
	fi
	tr -d '\r\n' <"$DB_PASSWORD_FILE"
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
	chown "$PG_OS_USER:" "$dest"
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
	chown "$PG_OS_USER:" "$TLS_DIR/server.key" "$TLS_DIR/server.crt"
	: >"$TLS_DIR/server.self-signed"
}

stage_tls() {
	mkdir -p "$TLS_DIR"
	chown "$PG_OS_USER:" "$TLS_DIR"
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

	# A replica dials the writer, so the client identity is required there; node 1 uses it
	# only to ask the other nodes where their data ends, which it checks for itself.
	if stage_pem CLIENT_CERT_FILE client.crt && stage_pem CLIENT_KEY_FILE client.key; then
		PG_HAVE_CLIENT=yes
	else
		drop_pem client.crt
		drop_pem client.key
		if ! pg_is_writer; then
			pg_fail "node $PG_SLOT is a replica: it needs client_cert and client_key to authenticate to the writer"
		fi
	fi

	if ! pg_is_writer && [ "$PG_HAVE_CA" != yes ]; then
		pg_fail "node $PG_SLOT is a replica: it needs ca to verify the writer"
	fi
	pg_note "staged the TLS material dir=$TLS_DIR ca=$PG_HAVE_CA client=$PG_HAVE_CLIENT"
}

# Memory and WAL sizes from this machine, in MB, into TUNE_* for write_config.
#   shared_buffers        25 % of memory
#   effective_cache_size  75 % of memory
#   maintenance_work_mem  1/16 of memory, 64 MB to 1 GB
#   max_wal_size          a quarter of the data directory's file system, 96 MB to 4 GB:
#                         room for bulk loads to checkpoint on time rather than on size,
#                         without letting pg_wal take over a small volume
#   min_wal_size          an eighth of that, at least 32 MB (two segments)
size_from_machine() {
	mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
	case "$mem_kb" in '' | *[!0-9]*) mem_kb=1048576 ;; esac
	mem_mb=$((mem_kb / 1024))
	TUNE_SHARED_BUFFERS_MB=$((mem_mb / 4))
	[ "$TUNE_SHARED_BUFFERS_MB" -ge 16 ] || TUNE_SHARED_BUFFERS_MB=16
	TUNE_CACHE_MB=$((mem_mb * 3 / 4))
	[ "$TUNE_CACHE_MB" -ge 64 ] || TUNE_CACHE_MB=64
	TUNE_MAINTENANCE_MB=$(clamp $((mem_mb / 16)) 64 1024)

	fs_kb=$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $2 }')
	case "$fs_kb" in '' | *[!0-9]*) fs_kb=4194304 ;; esac
	TUNE_MAX_WAL_MB=$(clamp $((fs_kb / 1024 / 4)) 96 4096)
	TUNE_MIN_WAL_MB=$(clamp $((TUNE_MAX_WAL_MB / 8)) 32 1024)
	pg_note "sized from the machine memory=${mem_mb}MB fs=$((fs_kb / 1024))MB shared_buffers=${TUNE_SHARED_BUFFERS_MB}MB effective_cache_size=${TUNE_CACHE_MB}MB max_wal_size=${TUNE_MAX_WAL_MB}MB"
}

clamp() {
	if [ "$1" -lt "$2" ]; then
		echo "$2"
	elif [ "$1" -gt "$3" ]; then
		echo "$3"
	else
		echo "$1"
	fi
}

# How many nodes the database has, node 1 included, from the peers list; 0 when no list
# was supplied, which says nothing either way.
peer_count() {
	if [ -s "$PEERS_CACHE" ]; then
		grep -c . "$PEERS_CACHE" || true
	else
		echo 0
	fi
}

# The peers list arrives as a file that may be withdrawn once the app has started, and a
# later service-manager restart must still see it. So each start that is handed one
# keeps a copy outside the durable root, and a start without one uses that copy.
stage_peers() {
	mkdir -p "$STATE_DIR"
	chmod 0755 "$STATE_DIR"
	# awk ends every line with a newline, the last one included: the list arrives
	# without a final one, and `read` drops a last line that has none.
	if [ -n "${PEERS_FILE:-}" ] && [ -r "$PEERS_FILE" ]; then
		tr -d '\r' <"$PEERS_FILE" | awk 'NF { print $1 }' >"$PEERS_CACHE.new"
		mv -f "$PEERS_CACHE.new" "$PEERS_CACHE"
	elif [ -n "${PEERS:-}" ]; then
		printf '%s\n' "$PEERS" | tr -d '\r' | awk 'NF { print $1 }' >"$PEERS_CACHE.new"
		mv -f "$PEERS_CACHE.new" "$PEERS_CACHE"
	fi
	if [ -s "$PEERS_CACHE" ]; then
		pg_note "peers: $(tr '\n' ' ' <"$PEERS_CACHE")"
	fi
}


# The other nodes of the database, one per line: the peers list without this node.
# Node 1 is recognised as WRITER (peers.first names it); any other node by the slot
# number its name ends with ({pool}-{N}.…).
other_peers() {
	[ -s "$PEERS_CACHE" ] || return 0
	while IFS= read -r peer || [ -n "$peer" ]; do
		[ -n "$peer" ] || continue
		[ "$peer" = "${WRITER:-}" ] && pg_is_writer && continue
		[ "$(peer_slot "$peer")" = "$PG_SLOT" ] && continue
		echo "$peer"
	done <"$PEERS_CACHE"
}

# The slot number a peer's name carries ({pool}-{N}.…), or nothing for a name that
# carries none.
peer_slot() {
	label=${1%%.*}
	label=${label%%:*}
	case "$label" in
	*-[0-9]*)
		n=${label##*-}
		case "$n" in '' | *[!0-9]*) ;; *) echo "$n" ;; esac
		;;
	esac
}

# The settings this app owns, written to an include directory so the files initdb (or
# pg_basebackup) produced stay untouched, and regenerated on every start. The role decides
# the rest: a primary has no standby settings; a standby streams from node 1 through its
# replication slot; a parked standby has nothing to stream from. postgresql.auto.conf is
# read after this directory, so any connection settings an older version or a copy left
# there are removed first.
write_config() {
	pgdata=$1
	role=$2
	conf_dir="$pgdata/conf.d"
	mkdir -p "$conf_dir"
	size_from_machine "$pgdata"
	if ! grep -q "^include_dir = 'conf.d'" "$pgdata/postgresql.conf"; then
		printf "\n# Settings managed by the postgres app.\ninclude_dir = 'conf.d'\n" >>"$pgdata/postgresql.conf"
	fi
	if [ -f "$pgdata/postgresql.auto.conf" ]; then
		sed -i '/^[[:space:]]*primary_conninfo[[:space:]]*=/d; /^[[:space:]]*primary_slot_name[[:space:]]*=/d' \
			"$pgdata/postgresql.auto.conf"
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

# Streaming replication. Each replica holds a physical slot on node 1 (replica_<N>), so
# node 1 keeps exactly the WAL its replicas still need; no extra WAL is kept by size.
# The slot's hold is bounded: past max_slot_wal_keep_size node 1 gives the slot up
# rather than fill its disk, and that replica re-seeds.
wal_level = replica
max_wal_senders = 16
max_replication_slots = 16
wal_keep_size = 0
max_slot_wal_keep_size = '${TUNE_MAX_WAL_MB}MB'
hot_standby = on
hot_standby_feedback = on
recovery_target_timeline = 'latest'

# Sized from this machine: memory for the caches, the data directory's file system for
# WAL. The defaults are for a 128 MB machine; a 1 GB max_wal_size made a bulk load
# checkpoint every few seconds. Change any of them with ALTER SYSTEM, which is read
# after this file.
shared_buffers = '${TUNE_SHARED_BUFFERS_MB}MB'
effective_cache_size = '${TUNE_CACHE_MB}MB'
maintenance_work_mem = '${TUNE_MAINTENANCE_MB}MB'
max_wal_size = '${TUNE_MAX_WAL_MB}MB'
min_wal_size = '${TUNE_MIN_WAL_MB}MB'
checkpoint_timeout = '15min'
checkpoint_completion_target = 0.9

# A segment no longer needed is deleted at the checkpoint rather than renamed and kept
# for reuse. Kept segments are rewritten with new WAL as they are reused, so under writes
# every capture carried pg_wal at close to max_wal_size, nearly all of it spares; with
# them deleted, a capture after the pre-capture checkpoint holds only the WAL still
# needed. Write throughput measured the same either way. min_wal_size is moot with it.
wal_recycle = off

# Logs go to the service's stderr, through the filter that sets each line's level.
log_destination = 'stderr'
logging_collector = off
log_line_prefix = '%m [%p] %q%u@%d '
CONF
	if [ "$PG_HAVE_CA" = yes ]; then
		echo "ssl_ca_file = '$TLS_DIR/ca.pem'" >>"$conf_dir/orc.conf"
	fi

	rm -f "$conf_dir/orc-standby.conf"
	case "$role" in
	primary)
		rm -f "$pgdata/standby.signal" "$pgdata/recovery.signal"
		;;
	standby)
		{
			echo "# Written by the postgres app on every start. Edits here are lost on restart."
			echo "primary_conninfo = '$(writer_conninfo)'"
			echo "primary_slot_name = '$(slot_name "$PG_SLOT")'"
		} >"$conf_dir/orc-standby.conf"
		: >"$pgdata/standby.signal"
		;;
	parked | recovering)
		# A standby with nothing to stream from: it replays what it holds and serves it
		# read-only, and answers where its data ends.
		: >"$pgdata/standby.signal"
		;;
	esac

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

	write_ident "$pgdata"
	chown -R "$PG_OS_USER:" "$conf_dir" "$pgdata/postgresql.conf" "$pgdata/pg_hba.conf" "$pgdata/pg_ident.conf"
	[ ! -e "$pgdata/standby.signal" ] || chown "$PG_OS_USER:" "$pgdata/standby.signal"
	chmod 0600 "$pgdata/pg_hba.conf" "$pgdata/pg_ident.conf"
}

# Any client certificate the configured CA issued may replicate; which certificates
# exist is the CA's business, not this file's. Scope the CA accordingly.
write_ident() {
	{
		echo "# Written by the postgres app on every start. Edits here are lost on restart."
		printf '%-14s %-18s %s\n' "# MAPNAME" SYSTEM-USERNAME PG-USERNAME
		printf '%-14s %-18s %s\n' "$IDENT_MAP" '/^.*$' "$REPLICATION_ROLE"
	} >"$1/pg_ident.conf"
}



prepare_dir() {
	mkdir -p "$1"
	chown "$PG_OS_USER:" "$1"
	chmod 0700 "$1"
}

# A cluster's system identifier, from its control file.
cluster_sysid() {
	LC_ALL=C pg_as_postgres "$PG_BIN/pg_controldata" -D "$1" 2>/dev/null |
		sed -n 's/^Database system identifier:[[:space:]]*//p'
}

# Stops a postmaster this script started on the given directory, if one runs.
stop_server() {
	if pg_running "$1"; then
		pg_as_postgres "$PG_BIN/pg_ctl" stop -w -t 300 -s -m fast -D "$1" >/dev/null 2>&1 || true
	fi
}

# A postmaster on the given directory for this script's own use: Unix socket only, so
# no client and no other node can reach it.
start_private() {
	pgdata=$1
	shift
	mkdir -p "$(dirname "$BOOTSTRAP_LOG")"
	: >"$BOOTSTRAP_LOG"
	chown "$PG_OS_USER:" "$BOOTSTRAP_LOG"
	pg_as_postgres "$PG_BIN/pg_ctl" start -w -t 3600 -s -D "$pgdata" -l "$BOOTSTRAP_LOG" \
		-o "-c listen_addresses='' -c unix_socket_directories='$PG_SOCKET_DIR' $*" || return
	# Crash recovery runs here, before the server the service runs, so this log is the
	# only place it shows. Information, not a warning: a cluster restored from a capture
	# of a running server recovers the same way.
	if grep -q 'not properly shut down' "$BOOTSTRAP_LOG"; then
		pg_note "the cluster was not shut down cleanly (the server was killed, the machine stopped, or it was restored from a capture); PostgreSQL recovered from its WAL: $(grep -E 'redo (starts|done|is not required)' "$BOOTSTRAP_LOG" | sed 's/^.*LOG:  //' | tr '\n' ' ')"
	fi
}

psql_local() {
	pg_as_postgres "$PG_BIN/psql" -X -q -w -h "$PG_SOCKET_DIR" -p "$PG_PORT" "$@"
}

# ---------------------------------------------------------------------------------------
# Node 1

start_primary() {
	pgdata=$PRIMARY_PGDATA
	pg_note "node 1: this node is the writer pgdata=$pgdata"
	prepare_dir "$PRIMARY_ROOT"
	password=$(app_password)
	promote=no

	if [ -s "$pgdata/PG_VERSION" ]; then
		have=$(tr -d '\r\n' <"$pgdata/PG_VERSION")
		[ "$have" = "$PG_MAJOR" ] || pg_fail "the stored cluster is PostgreSQL $have; this app runs $PG_MAJOR and does not upgrade in place"
		adopt_cluster "$pgdata"
	fi

	others=$(other_peers)
	sysid=""
	[ ! -s "$pgdata/PG_VERSION" ] || sysid=$(cluster_sysid "$pgdata")
	if [ -n "$sysid" ] && [ -s "$WRITER_OPEN" ] && [ "$(cat "$WRITER_OPEN")" = "$sysid" ]; then
		pg_note "this machine opened this cluster before; its data is the newest, asking nobody"
	elif [ -z "$others" ]; then
		pg_note "no other nodes listed; this node's data is the database's"
	else
		if [ "$PG_HAVE_CA" != yes ] || [ "$PG_HAVE_CLIENT" != yes ]; then
			pg_fail "node 1 must ask the other nodes where their data ends, which needs ca, client_cert and client_key"
		fi
		: >"$RECOVERING"
		writer_decide "$pgdata" "$others"
	fi

	if [ ! -s "$pgdata/PG_VERSION" ]; then
		init_cluster "$pgdata" "$password"
	fi

	write_config "$pgdata" primary
	[ "$promote" = no ] || : >"$pgdata/standby.signal"
	open_session "$pgdata" "$password" "$promote"
	password=""
	cluster_sysid "$pgdata" >"$WRITER_OPEN"
	rm -f "$RECOVERING"
	pg_note "starting the writer"
	exec_postgres "$pgdata"
}

# A restored or crash-stopped cluster may carry a pid file from a postmaster that no
# longer exists, and a restore may have changed its owner.
adopt_cluster() {
	if [ -e "$1/postmaster.pid" ] && ! pg_running "$1"; then
		pg_note "removing a stale postmaster.pid"
		rm -f "$1/postmaster.pid"
	fi
	if [ "$(stat -c %U "$1")" != "$PG_OS_USER" ]; then
		pg_note "taking ownership of the stored cluster for $PG_OS_USER"
		chown -R "$PG_OS_USER:" "$1"
	fi
	chmod 0700 "$1"
}

init_cluster() {
	pgdata=$1
	[ -n "$2" ] || pg_fail "a password is required to create the cluster; pass it as a file, e.g. --db_password=@/path/to/file"
	if [ -d "$pgdata" ] && [ -n "$(ls -A "$pgdata")" ]; then
		pg_fail "$pgdata holds files but no PostgreSQL cluster; refusing to initialize over them"
	fi
	prepare_dir "$pgdata"
	pg_note "initializing a new cluster"
	# No --pwfile: the superuser gets no password, on purpose. Host access is closed
	# until pg_hba.conf is written. Its report is routine; it is shown only on failure.
	if ! pg_as_postgres "$PG_BIN/initdb" -D "$pgdata" \
		--auth-local=peer --auth-host=reject \
		--encoding=UTF8 --locale=C.UTF-8 --data-checksums >"$STATE_DIR/initdb.log" 2>&1; then
		cat "$STATE_DIR/initdb.log" >&2
		pg_fail "initdb failed"
	fi
	rm -f "$STATE_DIR/initdb.log"
}

# Node 1 without proof that it holds the newest data: ask every other node where its
# data ends, and go on only when every node that may hold newer data has answered.
# Leaves the cluster to open in $pgdata (or nothing, for a new database) and sets
# promote=yes when existing data must start a new timeline before it opens.
writer_decide() {
	pgdata=$1
	others=$2
	ask_dir="$STATE_DIR/ask"
	pause=5
	round=0
	while :; do
		round=$((round + 1))
		rm -rf "$ask_dir"
		mkdir -p "$ask_dir"

		have_local=no
		if [ -s "$pgdata/PG_VERSION" ]; then
			if pg_local_position "$pgdata"; then
				have_local=yes
				local_desc=$(pg_show_position "$LOCAL_SYSID" "$LOCAL_TLI" "$LOCAL_LSN")
			else
				pg_fail "the cluster in $pgdata has a control file that cannot be read; move it away by hand to let this node decide again"
			fi
		elif [ -d "$pgdata" ] && [ -n "$(ls -A "$pgdata" 2>/dev/null)" ]; then
			pg_fail "$pgdata holds files but no PostgreSQL cluster; move them away by hand to let this node decide again"
		fi

		unknown="" report="" candidates=0 n=0
		for peer in $others; do
			n=$((n + 1))
			pg_ask_peer "$peer"
			case "$ASK_KIND" in
			unknown)
				unknown="$unknown $peer"
				report="$report; $peer: unknown, $ASK_REASON"
				;;
			empty)
				report="$report; $peer: empty"
				;;
			data)
				desc=$(pg_show_position "$ASK_SYSID" "$ASK_TLI" "$ASK_LSN")
				CONTAINS_HISTORY=$LOCAL_HISTORY
				if [ "$have_local" = yes ] &&
					pg_contains "$LOCAL_SYSID" "$LOCAL_TLI" "$LOCAL_LSN" "$ASK_SYSID" "$ASK_TLI" "$ASK_LSN"; then
					report="$report; $peer: $desc, contained in this node's"
				else
					CONTAINS_HISTORY=$ASK_HISTORY
					if [ "$have_local" = no ] ||
						pg_contains "$ASK_SYSID" "$ASK_TLI" "$ASK_LSN" "$LOCAL_SYSID" "$LOCAL_TLI" "$LOCAL_LSN"; then
						report="$report; $peer: $desc, newer"
						candidates=$((candidates + 1))
						echo "$peer $ASK_SYSID $ASK_TLI $ASK_LSN" >"$ask_dir/$candidates"
						printf '%s\n' "$ASK_HISTORY" >"$ask_dir/$candidates.history"
					else
						report="$report; $peer: $desc, DIVERGED from this node's data (not used)"
					fi
				fi
				;;
			esac
		done
		if [ "$have_local" = yes ]; then
			report="this node: $local_desc$report"
		else
			report="this node: no cluster$report"
		fi

		# The freshest candidate is the one containing every other; candidates that do
		# not line up are a conflict only an operator can settle.
		source="" conflict=no
		i=1
		while [ "$i" -le "$candidates" ]; do
			read -r c_peer c_sysid c_tli c_lsn <"$ask_dir/$i"
			CONTAINS_HISTORY=$(cat "$ask_dir/$i.history")
			all=yes
			j=1
			while [ "$j" -le "$candidates" ]; do
				read -r _ o_sysid o_tli o_lsn <"$ask_dir/$j"
				pg_contains "$c_sysid" "$c_tli" "$c_lsn" "$o_sysid" "$o_tli" "$o_lsn" || all=no
				j=$((j + 1))
			done
			if [ "$all" = yes ]; then
				source=$i
				break
			fi
			i=$((i + 1))
		done
		if [ "$candidates" -gt 0 ] && [ -z "$source" ]; then
			conflict=yes
		fi

		forced=no
		if [ -e "$FORCE_START" ]; then
			rm -f "$FORCE_START"
			forced=yes
		fi

		if [ "$forced" = no ] && { [ -n "$unknown" ] || [ "$conflict" = yes ]; }; then
			count=$(echo "$unknown" | wc -w)
			why="$count of $n nodes unknown"
			[ "$conflict" = no ] || why="$why, and the nodes ahead of this one hold data that diverged from each other"
			pg_warn "WAIT round $round: $why: $report; asking again in ${pause}s; to stop waiting: touch $FORCE_START"
			sleep "$pause"
			pause=$((pause * 2))
			[ "$pause" -le 60 ] || pause=60
			continue
		fi

		if [ "$forced" = yes ]; then
			pg_warn "FORCED by $FORCE_START: going on without$unknown; writes only they hold are given up: $report"
			if [ "$conflict" = yes ]; then
				# Of candidates that diverged from each other, take the newest timeline,
				# then the furthest position.
				source=$(for f in "$ask_dir"/[0-9]*; do
					case "$f" in *.history) continue ;; esac
					read -r _ _ t l <"$f"
					echo "$t $l $(basename "$f")"
				done | sort -k1,1n -k2,2n | tail -n 1 | cut -d' ' -f3)
			fi
		else
			pg_note "decided: $report"
		fi

		if [ -n "$source" ]; then
			read -r c_peer c_sysid c_tli c_lsn <"$ask_dir/$source"
			if [ "$have_local" = yes ]; then
				pg_note "copying from $c_peer ($(pg_show_position "$c_sysid" "$c_tli" "$c_lsn"); this node $local_desc)"
			else
				pg_note "copying from $c_peer ($(pg_show_position "$c_sysid" "$c_tli" "$c_lsn"); this node holds no cluster)"
			fi
			if ! copy_from "$c_peer" "$pgdata"; then
				pg_warn "the copy from $c_peer failed; deciding again"
				sleep "$pause"
				continue
			fi
			promote=yes
		elif [ "$have_local" = yes ]; then
			promote=yes
		elif [ "$forced" = yes ]; then
			pg_warn "FORCED with no data on any node that answered: creating a NEW, EMPTY database"
		else
			pg_note "no node holds data: creating a new database"
		fi
		rm -rf "$ask_dir"
		return 0
	done
}

# Replaces this node's cluster with a copy of a peer's. The local cluster is provably
# contained in the source's (or absent), and the durable root holds one cluster, so it is
# discarded first; the capture hook refuses while $RECOVERING exists, so the half-built
# copy never becomes a restore point.
copy_from() {
	peer=$1
	pgdata=$2
	stop_server "$pgdata"
	rm -rf "$pgdata"
	prepare_dir "$pgdata"
	log="$STATE_DIR/copy.log"
	if ! pg_as_postgres "$PG_BIN/pg_basebackup" -D "$pgdata" -X stream --checkpoint=fast \
		--no-password -d "$(pg_peer_conninfo "$peer")" 2>"$log"; then
		pg_warn "pg_basebackup from $peer failed: $(tail -n 3 "$log" | tr '\n' ' ')"
		rm -rf "$pgdata"
		prepare_dir "$pgdata"
		return 1
	fi
	# The copy is of a standby: drop its standby settings, so it opens as nothing but
	# what this node makes of it.
	rm -f "$pgdata/standby.signal" "$pgdata/recovery.signal" "$pgdata/conf.d/orc-standby.conf"
	pg_note "copied from $peer"
	return 0
}

# One private session on node 1's cluster before it opens: replay and start a new
# timeline when asked (promote=yes), reconcile the roles and the database when a password
# was supplied, and hold a replication slot for every other node listed.
open_session() {
	pgdata=$1
	password=$2
	promote=$3
	password_file="$TLS_DIR/app.password"
	if [ -n "$password" ]; then
		(
			umask 077
			printf '%s' "$password" >"$password_file"
		)
		chown "$PG_OS_USER:" "$password_file"
	fi
	if ! start_private "$pgdata"; then
		rm -f "$password_file"
		cat "$BOOTSTRAP_LOG" >&2
		pg_fail "the cluster did not start"
	fi
	status=0
	if [ "$promote" = yes ]; then
		pg_note "replaying the data this node holds, then starting a new timeline"
		if pg_as_postgres "$PG_BIN/pg_ctl" promote -w -t 3600 -s -D "$pgdata"; then
			pg_note "on a new timeline: $(psql_local -d postgres -A -t -c "SELECT ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int || ', at ' || pg_current_wal_lsn()" 2>/dev/null || echo '?')"
		else
			status=1
			pg_warn "promotion failed"
		fi
	fi
	if [ "$status" -eq 0 ] && [ -n "$password" ]; then
		pg_note "reconciling roles and the database over the socket"
		psql_local -v ON_ERROR_STOP=1 -d postgres \
			-v replicator="$REPLICATION_ROLE" -v app_user="$DB_USER" -v app_db="$DB_NAME" \
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
		[ "$status" -ne 0 ] || pg_note "roles reconciled role=$DB_USER db=$DB_NAME replication_role=$REPLICATION_ROLE"
	elif [ "$status" -eq 0 ]; then
		pg_note "no password supplied this start; leaving the existing roles as they are"
	fi
	rm -f "$password_file"
	[ "$status" -ne 0 ] || reconcile_slots || status=$?
	stop_server "$pgdata"
	if [ "$status" -ne 0 ]; then
		cat "$BOOTSTRAP_LOG" >&2
		pg_fail "preparing the writer failed (exit $status)"
	fi
}

# A slot per other node, so each replica's WAL is kept for it while it restarts. Slots of
# nodes no longer listed are dropped once nothing streams from them; with no list, or a
# name that carries no slot number, nothing is dropped.
reconcile_slots() {
	keep=""
	complete=yes
	for peer in $(other_peers); do
		n=$(peer_slot "$peer")
		if [ -z "$n" ]; then
			complete=no
			continue
		fi
		keep="$keep $(slot_name "$n")"
	done
	[ -s "$PEERS_CACHE" ] || complete=no
	for slot in $keep; do
		psql_local -v ON_ERROR_STOP=1 -d postgres -A -t -v slot="$slot" >/dev/null <<'SQL' || return 1
SELECT pg_create_physical_replication_slot(:'slot', true)
WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = :'slot');
SQL
	done
	if [ "$complete" = yes ]; then
		for slot in $(psql_local -d postgres -A -t -c \
			"SELECT slot_name FROM pg_replication_slots WHERE slot_type = 'physical' AND slot_name LIKE 'replica\\_%' AND NOT active"); do
			case " $keep " in
			*" $slot "*) ;;
			*)
				pg_note "dropping slot $slot: no such node any more"
				psql_local -d postgres -c "SELECT pg_drop_replication_slot('$slot')" >/dev/null || true
				;;
			esac
		done
	fi
	[ -z "$keep" ] || pg_note "replication slots:$keep"
}

# ---------------------------------------------------------------------------------------
# Replicas

start_replica() {
	pgdata=$REPLICA_PGDATA
	[ -n "${WRITER:-}" ] || pg_fail "node $PG_SLOT is a replica: set WRITER to the host name of the writer (node 1)"
	pg_note "node $PG_SLOT: this node is a replica of $WRITER pgdata=$pgdata"
	prepare_dir "$REPLICA_ROOT"
	prepare_dir "$REPLICA_LOCAL"
	rm -f "$RECOVERING" "$WRITER_OPEN"

	if [ -e "$RELEASE_PARKED" ]; then
		rm -f "$RELEASE_PARKED"
		if [ -e "$pgdata" ]; then
			aside="$REPLICA_LOCAL/parked-$(date -u +%Y%m%dT%H%M%SZ)"
			mv "$pgdata" "$aside"
			pg_note "released by $RELEASE_PARKED: this replica's cluster is kept at $aside (remove it when done); seeding afresh"
		fi
		rm -f "$PARKED"
	fi

	have_local=no
	if [ -s "$pgdata/PG_VERSION" ]; then
		adopt_cluster "$pgdata"
		if pg_local_position "$pgdata"; then
			have_local=yes
		else
			aside="$REPLICA_LOCAL/unreadable-$(date -u +%Y%m%dT%H%M%SZ)"
			rm -rf "$REPLICA_LOCAL"/unreadable-*
			mv "$pgdata" "$aside"
			pg_warn "this replica's control file cannot be read; its files are kept at $aside and it seeds afresh"
		fi
	elif [ -d "$pgdata" ]; then
		rm -rf "$pgdata"
	fi

	if [ "$have_local" = no ]; then
		rm -f "$PARKED"
		seed_replica "$pgdata"
		follow "$pgdata"
	fi

	local_desc=$(pg_show_position "$LOCAL_SYSID" "$LOCAL_TLI" "$LOCAL_LSN")
	pg_ask_peer "$WRITER"
	case "$ASK_KIND" in
	data)
		desc=$(pg_show_position "$ASK_SYSID" "$ASK_TLI" "$ASK_LSN")
		CONTAINS_HISTORY=$ASK_HISTORY
		if pg_contains "$ASK_SYSID" "$ASK_TLI" "$ASK_LSN" "$LOCAL_SYSID" "$LOCAL_TLI" "$LOCAL_LSN"; then
			rm -f "$PARKED"
			pg_note "node 1 ($desc) contains this replica's data ($local_desc); keeping it"
			if catch_up "$pgdata" "$ASK_LSN"; then
				follow "$pgdata"
			fi
			pg_warn "this replica cannot catch up from node 1 (the WAL it needs is gone); its data is contained in node 1's, so it seeds afresh"
			rm -rf "$pgdata"
			seed_replica "$pgdata"
			follow "$pgdata"
		fi
		reason="this replica holds data node 1 does not: this replica $local_desc, node 1 $desc"
		if [ "$ASK_SYSID" != "$LOCAL_SYSID" ]; then
			reason="this replica holds another cluster than node 1's (system $LOCAL_SYSID, $local_desc; node 1 system $ASK_SYSID)"
		fi
		park "$pgdata" "$reason"
		;;
	*)
		pg_warn "node 1 does not answer ($ASK_REASON); keeping this replica's data ($local_desc) and following node 1 when it is back"
		follow "$pgdata"
		;;
	esac
}

# Runs as a standby of node 1. Never returns.
follow() {
	write_config "$1" standby
	pg_note "starting the replica"
	exec_postgres "$1"
}

# Keeps the data, refuses to stream over it, and serves it read-only: an operator can read
# it, a later node 1 can ask where it ends, and the readiness probe reports unready.
park() {
	printf '%s\n' "$2" >"$PARKED"
	pg_warn "PARKED: $2. The data is kept and served read-only; nothing streams into it. To discard it from this replica (it is moved aside, not deleted) and seed from node 1: touch $RELEASE_PARKED and restart the app"
	write_config "$1" parked
	exec_postgres "$1"
}

# Streams from node 1 on a private postmaster until this replica holds node 1's position
# as it was when asked. Fails when streaming does not get there within CATCH_UP_TIMEOUT.
catch_up() {
	pgdata=$1
	target=$2
	timeout=${CATCH_UP_TIMEOUT:-120}
	write_config "$pgdata" standby
	ensure_slot
	if ! start_private "$pgdata"; then
		cat "$BOOTSTRAP_LOG" >&2
		pg_fail "this replica's cluster did not start"
	fi
	deadline=$(($(date +%s) + timeout))
	ok=no
	while [ "$(date +%s)" -lt "$deadline" ]; do
		row=$(psql_local -d postgres -A -t -c \
			"SELECT status, COALESCE(flushed_lsn::text, '') FROM pg_stat_wal_receiver" 2>/dev/null || true)
		status=${row%%|*}
		flushed=${row#*|}
		if [ "$status" = streaming ]; then
			if [ "$LOCAL_LSN" -ge "$target" ] || { [ -n "$flushed" ] && [ "$(lsn_dec "$flushed")" -ge "$target" ]; }; then
				ok=yes
				break
			fi
		fi
		sleep 2
	done
	stop_server "$pgdata"
	if [ "$ok" = yes ]; then
		pg_note "streaming from node 1 and caught up to $(lsn_hex "$target")"
		return 0
	fi
	pg_warn "not caught up within ${timeout}s: $(grep -E 'FATAL|ERROR' "$BOOTSTRAP_LOG" | tail -n 2 | tr '\n' ' ')"
	return 1
}


# Copies node 1 into an empty data directory. Until node 1 answers, the stand-in answers
# for this node as empty, so a node 1 deciding whether anyone holds newer data does not
# wait on a node that holds none.
seed_replica() {
	pgdata=$1
	log="$REPLICA_LOCAL/seed.log"
	attempt=0
	while :; do
		standin_start
		while :; do
			pg_ask_peer "$WRITER"
			[ "$ASK_KIND" != data ] || break
			attempt=$((attempt + 1))
			if [ $((attempt % 6)) -eq 1 ]; then
				pg_note "waiting for node 1 to open before seeding ($ASK_REASON); this node answers as empty meanwhile"
			fi
			sleep "$SEED_INTERVAL"
		done
		standin_stop
		prepare_dir "$pgdata"
		slot_opt=""
		if ensure_slot; then
			slot_opt="-S $(slot_name "$PG_SLOT")"
		fi
		# shellcheck disable=SC2086 # slot_opt is two words or none
		if pg_as_postgres "$PG_BIN/pg_basebackup" -D "$pgdata" -X stream --checkpoint=fast \
			$slot_opt --no-password -d "$(writer_conninfo)" 2>"$log"; then
			break
		fi
		pg_warn "seeding from $WRITER failed, retrying in ${SEED_INTERVAL}s: $(tail -n 2 "$log" | tr '\n' ' ')"
		rm -rf "$pgdata"
		sleep "$SEED_INTERVAL"
	done
	rm -f "$log" "$pgdata/standby.signal"
	sed -i '/^[[:space:]]*primary_conninfo[[:space:]]*=/d; /^[[:space:]]*primary_slot_name[[:space:]]*=/d' \
		"$pgdata/postgresql.auto.conf" 2>/dev/null || true
	pg_note "seeded from $WRITER"
	pg_local_position "$pgdata" || true
}

# ---------------------------------------------------------------------------------------
# The stand-in: a throwaway cluster that answers a replication connection, and nothing
# else, with cluster_name set to the empty marker. It never holds data, is never
# reachable by the application role (there is none, and every rule but certificate
# replication rejects), is stopped and deleted before this node seeds, and the
# readiness probe fails while it exists.

standin_start() {
	standin_stop
	prepare_dir "$STANDIN_DIR"
	if [ "$PG_HAVE_CA" != yes ]; then
		pg_warn "no ca: the stand-in cannot authenticate node 1, so this node does not answer as empty"
		return 0
	fi
	data="$STANDIN_DIR/data"
	pg_as_postgres "$PG_BIN/initdb" -D "$data" -U "$REPLICATION_ROLE" --no-sync \
		--auth-local=reject --auth-host=reject --encoding=UTF8 --locale=C.UTF-8 \
		>"$STANDIN_DIR/initdb.log" 2>&1 || {
		pg_warn "the stand-in could not be created: $(tail -n 2 "$STANDIN_DIR/initdb.log" | tr '\n' ' ')"
		return 0
	}
	{
		printf '%-10s %-13s %-20s %-9s %s\n' local all all "" reject
		printf '%-10s %-13s %-20s %-9s %s\n' hostssl replication "$REPLICATION_ROLE" all "cert map=$IDENT_MAP"
		printf '%-10s %-13s %-20s %-9s %s\n' host all all all reject
	} >"$data/pg_hba.conf"
	write_ident "$data"
	chown "$PG_OS_USER:" "$data/pg_hba.conf" "$data/pg_ident.conf"
	pg_as_postgres "$PG_BIN/pg_ctl" start -w -t 60 -s -D "$data" -l "$STANDIN_DIR/log" \
		-o "-c listen_addresses='*' -c port=$PG_PORT -c unix_socket_directories='$STANDIN_DIR' \
-c cluster_name='$STANDIN_MARK' -c max_connections=4 -c superuser_reserved_connections=0 \
-c reserved_connections=0 -c shared_buffers=1MB -c max_wal_senders=2 -c fsync=off \
-c ssl=on -c ssl_cert_file='$TLS_DIR/server.crt' -c ssl_key_file='$TLS_DIR/server.key' \
-c ssl_ca_file='$TLS_DIR/ca.pem'" || {
		pg_warn "the stand-in did not start: $(tail -n 3 "$STANDIN_DIR/log" | tr '\n' ' ')"
		return 0
	}
	pg_note "no cluster here: answering as empty until node 1 opens"
}

standin_stop() {
	if [ -d "$STANDIN_DIR/data" ]; then
		stop_server "$STANDIN_DIR/data"
	fi
	rm -rf "$STANDIN_DIR"
}

# ---------------------------------------------------------------------------------------

exec_postgres() {
	# The watcher logs replication lag and states next to the server. It is detached from
	# this process before the exec, so the postmaster never inherits it as a child.
	(sh "$SCRIPT_DIR/watch-postgres.sh" "$$" </dev/null &)
	# The server writes its whole log to stderr. It goes through a FIFO to
	# postgres-log.awk, which passes trouble on to stderr (a warning in the node log) and
	# everything else to stdout (information); see "What an operator sees" in README.md. The postmaster
	# stays this process. fd 3 holds the FIFO open read-write while the two ends are
	# opened, so neither open waits for the other, and is closed before the exec: from
	# then on the filter is the only reader, so if it ever died a log write would fail
	# (the server ignores SIGPIPE) rather than block. The filter ignores the stop signal,
	# which reaches every process of the service, and ends at end of file, once the
	# postmaster and its children have exited and written their last lines.
	fifo="$STATE_DIR/log.fifo"
	rm -f "$fifo"
	mkfifo -m 600 "$fifo"
	exec 3<>"$fifo"
	(
		trap '' HUP INT TERM
		awk -f "$SCRIPT_DIR/postgres-log.awk" <"$fifo" 3<&- &
	)
	if [ "$(id -u)" -eq "$(id -u "$PG_OS_USER")" ]; then
		exec env PATH="$PG_BIN:/usr/bin:/bin" "$PG_BIN/postgres" -D "$1" 2>"$fifo" 3<&-
	fi
	exec setpriv --reuid="$PG_OS_USER" --regid="$PG_OS_USER" --init-groups \
		env HOME=/var/lib/postgresql PATH="$PG_BIN:/usr/bin:/bin" \
		"$PG_BIN/postgres" -D "$1" 2>"$fifo" 3<&-
}

stage_tls
stage_peers
standin_stop
if pg_is_writer; then
	start_primary
else
	start_replica
fi
