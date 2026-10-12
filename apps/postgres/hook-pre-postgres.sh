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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_PHASE=hook_pre
# shellcheck source=postgres-common.sh
. "$SCRIPT_DIR/postgres-common.sh"

CHECKPOINT_AFTER_MB=${CHECKPOINT_AFTER_MB:-64}

if ! pg_is_writer; then
	pg_note "slot $PG_SLOT: replica, nothing durable here"
	sync
	exit 0
fi

if [ ! -s "$PRIMARY_PGDATA/PG_VERSION" ]; then
	pg_note "no cluster in the durable root yet"
	sync
	exit 0
fi

if ! command -v setpriv >/dev/null 2>&1 || ! pg_running "$PRIMARY_PGDATA"; then
	pg_note "the writer is not running; its data is at rest"
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
	pg_note "the writer is not taking writes; capturing as it is"
	sync
	exit 0
	;;
esac

if [ "$since" -lt $((CHECKPOINT_AFTER_MB * 1024 * 1024)) ]; then
	pg_note "$((since / 1024)) kB of WAL since the last checkpoint; capturing without one"
	sync
	exit 0
fi

pg_note "$((since / 1024 / 1024)) MB of WAL since the last checkpoint; checkpointing before the capture"
pg_as_postgres "$PG_BIN/psql" -X -q -w -v ON_ERROR_STOP=1 \
	-h "$PG_SOCKET_DIR" -p "$PG_PORT" -d postgres -c 'CHECKPOINT' >/dev/null \
	|| pg_fail "CHECKPOINT failed; skipping this capture"
sync
pg_note "checkpoint written"
