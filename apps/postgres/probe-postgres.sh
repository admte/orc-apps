#!/bin/sh
# Readiness of the pg endpoint: the server accepts connections, and this node is in a
# state clients should be sent to. Unready while node 1 decides or copies, while a node
# with no cluster runs the empty stand-in, and while a replica is parked on data node 1
# lacks. Readiness steers name resolution only; it never causes a node to be replaced.
#
# The probe runs without the app's parameters, so it relies on fixed paths alone.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_PHASE=probe
# shellcheck source=postgres-common.sh
. "$SCRIPT_DIR/postgres-common.sh"

[ ! -e "$RECOVERING" ] || exit 1
[ ! -e "$STANDIN_DIR" ] || exit 1
[ ! -e "$PARKED" ] || exit 1
[ -S "$PG_SOCKET_DIR/.s.PGSQL.$PG_PORT" ] || exit 1
if command -v pg_isready >/dev/null 2>&1; then
	exec pg_isready -q -h "$PG_SOCKET_DIR" -p "$PG_PORT"
fi
exit 0
