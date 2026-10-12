#!/bin/sh
# Where a cluster's data ends, and whether one node's data contains another's. Sourced by
# the start phase, never executed. See "Recovery and durability" in README.md.
#
# A position is three words: the cluster's system identifier, a timeline, and a WAL
# position in decimal bytes. Node 1 never decides from a guess, so every function here
# either answers exactly or says it could not.

# The conninfo for a replication connection to a peer, authenticated by this node's
# client certificate and verifying the peer's server certificate against the CA.
pg_peer_conninfo() {
	pg_split_host "$1"
	printf 'host=%s port=%s user=%s sslmode=verify-full sslrootcert=%s sslcert=%s sslkey=%s connect_timeout=5 application_name=%s' \
		"$PEER_HOST" "$PEER_PORT" "$REPLICATION_ROLE" "$TLS_DIR/ca.pem" \
		"$TLS_DIR/client.crt" "$TLS_DIR/client.key" "$CLUSTER_NAME-$PG_SLOT-ask"
}

# Hex LSN (0/C46EBE0) to decimal bytes, and back.
lsn_dec() {
	hi=${1%/*}
	lo=${1#*/}
	echo $(((0x$hi << 32) + 0x$lo))
}

lsn_hex() {
	printf '%X/%X' $(($1 >> 32)) $(($1 & 0xFFFFFFFF))
}

# Asks a peer where its data ends, over a replication connection. Sets ASK_KIND to one of
#   data     ASK_SYSID ASK_TLI ASK_LSN are set, and ASK_HISTORY holds the timeline history
#   empty    the peer runs the stand-in: it holds no cluster
#   unknown  the peer did not answer; ASK_REASON says how
# and returns 0 in every case.
pg_ask_peer() {
	ASK_KIND=unknown ASK_SYSID="" ASK_TLI="" ASK_LSN="" ASK_HISTORY="" ASK_REASON=""
	conninfo="$(pg_peer_conninfo "$1") replication=true"
	if ! out=$(pg_as_postgres "$PG_BIN/psql" -X -A -t -q -w -d "$conninfo" \
		-c 'SHOW cluster_name' -c 'IDENTIFY_SYSTEM' 2>&1); then
		ASK_REASON=$(printf '%s' "$out" | tr '\n' ' ' | sed 's/^psql: //; s/  */ /g')
		case "$ASK_REASON" in
		*"could not translate host name"* | *"Name or service not known"* | *"Temporary failure in name resolution"*)
			ASK_REASON="offline (its name answers nothing)"
			;;
		*"Connection refused"*)
			ASK_REASON="nothing listening (PostgreSQL is down or still starting)"
			;;
		*"timeout expired"*)
			ASK_REASON="no answer within 5s"
			;;
		esac
		return 0
	fi
	name=$(printf '%s\n' "$out" | sed -n 1p)
	if [ "$name" = "$STANDIN_MARK" ]; then
		ASK_KIND=empty
		return 0
	fi
	ident=$(printf '%s\n' "$out" | sed -n 2p)
	ASK_SYSID=$(echo "$ident" | cut -d'|' -f1)
	ASK_TLI=$(echo "$ident" | cut -d'|' -f2)
	lsn=$(echo "$ident" | cut -d'|' -f3)
	case "$ASK_SYSID:$ASK_TLI:$lsn" in
	*[!0-9A-Fa-f:/]* | :* | *::* | *:)
		ASK_REASON="an answer this app cannot read: $ident"
		return 0
		;;
	esac
	ASK_LSN=$(lsn_dec "$lsn")
	if [ "$ASK_TLI" -gt 1 ]; then
		if ! hist=$(pg_as_postgres "$PG_BIN/psql" -X -A -t -q -w -d "$conninfo" \
			-c "TIMELINE_HISTORY $ASK_TLI" 2>&1); then
			ASK_REASON="no timeline history: $(printf '%s' "$hist" | tr '\n' ' ')"
			return 0
		fi
		ASK_HISTORY=$(printf '%s\n' "$hist" | sed '1s/^[^|]*|//' | history_lines)
	fi
	ASK_KIND=data
}

# The "parent-timeline switchpoint" lines of a timeline history file, LSNs in decimal.
history_lines() {
	tr -d '\r' | grep -E '^[0-9]+[[:space:]]+[0-9A-Fa-f]+/[0-9A-Fa-f]+' | while read -r tli lsn _; do
		echo "$tli $(lsn_dec "$lsn")"
	done
}

# Where this machine's cluster ends, read from its files while no server runs on it. Sets
# LOCAL_SYSID LOCAL_TLI LOCAL_LSN LOCAL_HISTORY, or returns 1 when the control file cannot
# be read.
#
# The control file alone is not enough: it records the last checkpoint, and a restored or
# crashed cluster holds WAL past it. pg_waldump reads that WAL to its last complete record,
# on the newest timeline the cluster has a history file for.
pg_local_position() {
	pgdata=$1
	control=$(LC_ALL=C pg_as_postgres "$PG_BIN/pg_controldata" -D "$pgdata" 2>/dev/null) || return 1
	field() { printf '%s\n' "$control" | sed -n "s/^$1:[[:space:]]*//p" | head -n 1; }
	LOCAL_SYSID=$(field 'Database system identifier')
	ckpt_tli=$(field "Latest checkpoint's TimeLineID")
	redo=$(field "Latest checkpoint's REDO location")
	minrec=$(field 'Minimum recovery ending location')
	minrec_tli=$(field "Min recovery ending loc's timeline")
	seg=$(field 'Bytes per WAL segment')
	blk=$(field 'WAL block size')
	case "$LOCAL_SYSID:$ckpt_tli:$seg:$blk" in
	*[!0-9:]* | :* | *::* | *:) return 1 ;;
	esac
	[ -n "$redo" ] || return 1

	# The newest timeline: the checkpoint's, or a later one a promotion or a followed
	# switch left a history file for.
	LOCAL_TLI=$ckpt_tli
	for h in "$pgdata"/pg_wal/*.history; do
		[ -e "$h" ] || continue
		t=$(basename "$h" .history)
		case "$t" in *[!0-9A-Fa-f]*) continue ;; esac
		t=$((0x$t))
		[ "$t" -gt "$LOCAL_TLI" ] && LOCAL_TLI=$t
	done
	LOCAL_HISTORY=""
	hist_file="$pgdata/pg_wal/$(printf '%08X' "$LOCAL_TLI").history"
	if [ "$LOCAL_TLI" -gt 1 ] && [ -r "$hist_file" ]; then
		LOCAL_HISTORY=$(history_lines <"$hist_file")
	fi

	# Read from the checkpoint's redo point, or from where the newest timeline began when
	# it began after that checkpoint.
	start=$(lsn_dec "$redo")
	if [ "$LOCAL_TLI" -gt "$ckpt_tli" ] && [ -n "$LOCAL_HISTORY" ]; then
		start=$(printf '%s\n' "$LOCAL_HISTORY" | tail -n 1 | cut -d' ' -f2)
	fi
	floor=$start
	if [ -n "$minrec" ] && [ "$minrec_tli" = "$LOCAL_TLI" ]; then
		m=$(lsn_dec "$minrec")
		[ "$m" -gt "$floor" ] && floor=$m
	fi

	LOCAL_LSN=$(LC_ALL=C pg_as_postgres "$PG_BIN/pg_waldump" -p "$pgdata/pg_wal" \
		-t "$LOCAL_TLI" -s "$(lsn_hex "$start")" 2>/dev/null |
		wal_end "$seg" "$blk")
	if [ -z "$LOCAL_LSN" ] || [ "$LOCAL_LSN" -lt "$floor" ]; then
		LOCAL_LSN=$floor
	fi
	return 0
}

# The end of the last record pg_waldump printed: its start plus its length, with the page
# header of every page boundary the record crosses, rounded up to 8 bytes -- where the
# next record would begin, which is what a standby reports as the end of what it holds.
wal_end() {
	awk -v seg="$1" -v blk="$2" '
		/^rmgr:/ {
			for (i = 1; i <= NF; i++) {
				if ($i == "lsn:") { lsn = $(i + 1); sub(",", "", lsn) }
				if ($i == "(rec/tot):") { tot = $(i + 2); sub(",", "", tot) }
			}
			last = lsn; lasttot = tot
		}
		function hex(s,   n, i, c) {
			n = 0; s = toupper(s)
			for (i = 1; i <= length(s); i++) { c = index("0123456789ABCDEF", substr(s, i, 1)) - 1; n = n * 16 + c }
			return n
		}
		END {
			if (last == "") exit
			split(last, p, "/")
			pos = hex(p[1]) * 4294967296 + hex(p[2])
			rem = lasttot + 0
			while (rem > 0) {
				room = blk - (pos % blk)
				if (rem <= room) { pos += rem; rem = 0 }
				else {
					rem -= room; pos += room
					pos += (pos % seg == 0) ? 40 : 24
				}
			}
			if (pos % 8) pos += 8 - (pos % 8)
			printf "%.0f\n", pos
		}'
}

# Whether data A contains data B: the same cluster, and B's position on A's history. A is
# given as SYSID TLI LSN with its history in CONTAINS_HISTORY ("tli switchpoint" lines);
# B as SYSID TLI LSN.
pg_contains() {
	[ "$1" = "$4" ] || return 1
	a_tli=$2 a_lsn=$3 b_tli=$5 b_lsn=$6
	if [ "$b_tli" -eq "$a_tli" ]; then
		[ "$b_lsn" -le "$a_lsn" ]
		return
	fi
	[ "$b_tli" -lt "$a_tli" ] || return 1
	switch=$(printf '%s\n' "$CONTAINS_HISTORY" | awk -v t="$b_tli" '$1 == t { print $2; exit }')
	[ -n "$switch" ] || return 1
	[ "$b_lsn" -le "$switch" ]
}

# The replication slot node 1 holds for the replica in slot N.
slot_name() {
	echo "replica_$1"
}

# verify-full: node 1's certificate has to be issued by the configured CA and carry the
# name this replica dialed.
writer_conninfo() {
	pg_split_host "$WRITER"
	printf 'host=%s port=%s user=%s sslmode=verify-full sslrootcert=%s sslcert=%s sslkey=%s application_name=%s' \
		"$PEER_HOST" "$PEER_PORT" "$REPLICATION_ROLE" "$TLS_DIR/ca.pem" \
		"$TLS_DIR/client.crt" "$TLS_DIR/client.key" "$CLUSTER_NAME-$PG_SLOT"
}

# Makes sure node 1 holds this replica's slot. Node 1 creates the slots of the nodes it
# knows of when it opens; a replica whose slot node 1 lacks (added by hand, or node 1
# copied its cluster from a node and could not tell the others' numbers) creates its own.
ensure_slot() {
	out=$(pg_as_postgres "$PG_BIN/psql" -X -A -t -q -w \
		-d "$(writer_conninfo) replication=true" \
		-c "CREATE_REPLICATION_SLOT $(slot_name "$PG_SLOT") PHYSICAL RESERVE_WAL" 2>&1) && return 0
	case "$out" in
	*"already exists"*) return 0 ;;
	esac
	pg_note "could not make sure node 1 holds slot $(slot_name "$PG_SLOT"): $(printf '%s' "$out" | tr '\n' ' ')"
	return 1
}
# Human form of a position, for the log.
pg_show_position() {
	printf 'timeline %s, %s' "$2" "$(lsn_hex "$3")"
}
