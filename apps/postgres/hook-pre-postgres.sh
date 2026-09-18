#!/bin/sh
set -eu

# Capture hook: runs right before the platform snapshots the persisted root. A
# snapshot of a running cluster is crash-consistent on its own; the checkpoint written
# here keeps the WAL that a restored cluster has to replay short, and the sync pushes
# everything the checkpoint wrote to the disk the snapshot is taken from.
#
# Only slot 1 keeps anything in the persisted root. A replica's root is empty, so it
# has nothing to make consistent, and a writer whose postmaster is down is already
# at rest. A non-zero exit here skips the capture, so it is reserved for a checkpoint
# that was asked for and refused.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_PHASE=hook_pre
# shellcheck source=postgres-common.sh
. "$SCRIPT_DIR/postgres-common.sh"

if ! pg_is_writer; then
	pg_note "slot ${SLOT:-?}: replica, nothing persisted here"
	sync
	exit 0
fi

if [ ! -s "$PRIMARY_PGDATA/PG_VERSION" ]; then
	pg_note "no cluster in the persisted root yet"
	sync
	exit 0
fi

if ! command -v setpriv >/dev/null 2>&1 || ! pg_running "$PRIMARY_PGDATA"; then
	pg_note "the writer is not running; its data is at rest"
	sync
	exit 0
fi

pg_note "checkpointing the writer before the capture"
pg_as_postgres "$PG_BIN/psql" -X -q -w -v ON_ERROR_STOP=1 \
	-h "$PG_SOCKET_DIR" -p "$PG_PORT" -d postgres -c 'CHECKPOINT' >/dev/null \
	|| pg_fail "CHECKPOINT failed; skipping this capture"
sync
pg_note "checkpoint written"
