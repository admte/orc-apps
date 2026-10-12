#!/bin/sh
set -u

# Runs next to the server for as long as it runs, started by the start phase just before
# it execs the postmaster (whose pid is $1), and writes to the same log.
#
# On node 1 it reports replication lag per replica: every minute while any replica is more
# than LAG_WARN_SECONDS behind or disconnected, otherwise every ten minutes. On a replica
# it reports a parked state every ten minutes, and every minute while it is not streaming
# from node 1. It reads and logs, with one exception: a replica that is not streaming
# because node 1 lacks its replication slot creates that slot on node 1, which is what
# the replica's own start would do.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_PHASE=watch
# shellcheck source=postgres-common.sh
. "$SCRIPT_DIR/postgres-common.sh"
# shellcheck source=postgres-position.sh
. "$SCRIPT_DIR/postgres-position.sh"

server=$1
LAG_WARN_SECONDS=${LAG_WARN_SECONDS:-1}
QUIET_EVERY=600
LOUD_EVERY=60

pg_note() {
	echo "postgres lag: $*" >&2
}

sql() {
	pg_as_postgres "$PG_BIN/psql" -X -q -w -A -t -F ' ' -h "$PG_SOCKET_DIR" -p "$PG_PORT" -d postgres -c "$1" 2>/dev/null
}

alive() {
	kill -0 "$server" 2>/dev/null
}

# Sleeps up to $1 seconds, returning early (non-zero) when the server is gone.
nap() {
	left=$1
	while [ "$left" -gt 0 ]; do
		alive || return 1
		sleep 5
		left=$((left - 5))
	done
}

writer_report() {
	# One line per replica slot, plus any replica streaming without one.
	sql "
SELECT COALESCE(s.slot_name, r.application_name, '?'),
       COALESCE(r.state, 'disconnected'),
       COALESCE(round(extract(epoch FROM r.flush_lag)::numeric, 2), 0),
       COALESCE(round(extract(epoch FROM r.replay_lag)::numeric, 2), 0),
       COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), r.flush_lsn),
                pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn), 0)::bigint,
       COALESCE(s.wal_status, '-')
FROM pg_replication_slots s
FULL JOIN pg_stat_replication r ON r.pid = s.active_pid
WHERE s.slot_name IS NULL OR s.slot_name LIKE 'replica\\_%'
ORDER BY 1"
}

human_bytes() {
	b=$1
	if [ "$b" -ge 1073741824 ]; then
		echo "$((b / 1073741824)) GB"
	elif [ "$b" -ge 1048576 ]; then
		echo "$((b / 1048576)) MB"
	elif [ "$b" -ge 1024 ]; then
		echo "$((b / 1024)) kB"
	else
		echo "$b B"
	fi
}

# Give the server a moment to open before the first look.
nap ${WATCH_FIRST_LOOK:-30} || exit 0
last=0
while alive; do
	now=$(date +%s)
	loud=no
	line=""
	if pg_is_writer; then
		rows=$(writer_report || true)
		if [ -n "$rows" ]; then
			while read -r name state flush replay bytes walst; do
				[ -n "$name" ] || continue
				if [ "$state" = streaming ]; then
					part="$name streaming, flush ${flush}s replay ${replay}s behind, $(human_bytes "$bytes") behind"
					awk -v f="$flush" -v w="$LAG_WARN_SECONDS" 'BEGIN { exit !(f > w) }' && loud=yes
				else
					part="$name $state, $(human_bytes "$bytes") behind (slot $walst)"
					loud=yes
				fi
				line="${line:+$line; }$part"
			done <<ROWS
$rows
ROWS
		fi
	else
		if [ -s "$PARKED" ]; then
			line="PARKED: $(cat "$PARKED"); release with: touch $RELEASE_PARKED, then restart the app"
		else
			row=$(sql "SELECT status, COALESCE(round(extract(epoch FROM now() - pg_last_xact_replay_timestamp())::numeric, 1)::text, '-') FROM pg_stat_wal_receiver" || true)
			status=${row%% *}
			if [ "$status" = streaming ]; then
				line="streaming from node 1"
			else
				line="NOT streaming from node 1 (receiver: ${status:-none}); this replica falls behind until it does"
				loud=yes
				ensure_slot 2>/dev/null || true
			fi
		fi
	fi
	every=$QUIET_EVERY
	[ "$loud" = no ] || every=$LOUD_EVERY
	if [ -n "$line" ] && [ $((now - last)) -ge "$every" ]; then
		if [ "$loud" = yes ]; then
			pg_note "WARNING: $line"
		else
			pg_note "$line"
		fi
		last=$now
	fi
	nap "$LOUD_EVERY" || break
done
