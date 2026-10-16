#!/bin/sh
set -eu

# Capture hook: runs right before something snapshots the durable root -- a backup job,
# a volume snapshot, an orchestrator capturing app data. A snapshot of the volume is
# crash-consistent on its own: a restored cluster replays its WAL from the last
# checkpoint, exactly as after a power cut, and loses nothing that was committed. So no
# checkpoint is needed for correctness; one only bounds how much WAL that replay reads.
#
# The checkpoint is therefore taken only when that bound is worth paying for: when more
# than CHECKPOINT_AFTER_MB of WAL has been written since the last one. Forcing one on
# every capture was costly both ways: on an idle database each checkpoint writes WAL of
# its own, so the volume never went quiet and every capture found something new (16 MB
# every ~76 s for zero client writes), and under load each extra checkpoint makes the
# next write to every page a full-page image, inflating WAL and the captures with it.
# The checkpointer still runs on its own schedule (checkpoint_timeout, max_wal_size).
#
# Only the writer keeps anything in the durable root. A replica's root is empty, so it
# has nothing to make consistent, and a writer whose postmaster is down is already at
# rest. A non-zero exit here skips the capture, so it is reserved for a checkpoint that
# was asked for and refused.
#
# The hook runs on every capture, every few minutes, so its ordinary outcomes are not
# logged: the node log would fill with the same line. Only a refusal is.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_PHASE=hook_pre
# shellcheck source=postgres-common.sh
. "$SCRIPT_DIR/postgres-common.sh"

CHECKPOINT_AFTER_MB=${CHECKPOINT_AFTER_MB:-64}

# A replica keeps nothing durable here.
if ! pg_is_writer; then
	sync
	exit 0
fi

# While node 1 decides whether another node holds newer data, or copies from one, its
# durable root is not the database's yet: a capture now could become a restore point
# older or emptier than what the replicas hold. Refusing skips this capture.
if [ -e "$RECOVERING" ]; then
	pg_fail "node 1 is still deciding or copying before it opens; skipping this capture"
fi

# No cluster in the durable root yet, or a writer that is not running: at rest already.
if [ ! -s "$PRIMARY_PGDATA/PG_VERSION" ]; then
	sync
	exit 0
fi

if ! command -v setpriv >/dev/null 2>&1 || ! pg_running "$PRIMARY_PGDATA"; then
	sync
	exit 0
fi

# WAL written since the last checkpoint began, in bytes. Empty while the server is not
# accepting connections (starting, or a standby), in which case there is nothing to
# shorten: leave it to the snapshot.
since=$(pg_as_postgres "$PG_BIN/psql" -X -q -w -A -t \
	-h "$PG_SOCKET_DIR" -p "$PG_PORT" -d postgres -c \
	"SELECT CASE WHEN pg_is_in_recovery() THEN NULL ELSE pg_wal_lsn_diff(pg_current_wal_insert_lsn(), redo_lsn)::bigint END FROM pg_control_checkpoint()" \
	2>/dev/null || true)
case "$since" in
'' | *[!0-9]*)
	sync
	exit 0
	;;
esac

# Too little WAL to be worth a checkpoint: capture as it is.
if [ "$since" -lt $((CHECKPOINT_AFTER_MB * 1024 * 1024)) ]; then
	sync
	exit 0
fi

pg_as_postgres "$PG_BIN/psql" -X -q -w -v ON_ERROR_STOP=1 \
	-h "$PG_SOCKET_DIR" -p "$PG_PORT" -d postgres -c 'CHECKPOINT' >/dev/null \
	|| pg_fail "CHECKPOINT failed; skipping this capture"
sync
