# The server log's router. The postmaster writes its whole log to stderr, which
# start-postgres.sh points at a FIFO this filter reads; the node logs what an app prints on
# stdout as information and what it prints on stderr as a warning, so each line is
# written to the one that says how much it matters:
#
#   stderr (warning)  ERROR, FATAL and PANIC; a WARNING from the server itself (not from a
#                     client's session), or one telling a session that the server crashed
#                     or that the database must be vacuumed; and the LOG lines that report a
#                     crash or a lost replication slot.
#   stdout (info)     everything else: LOG, INFO, NOTICE, DEBUG, a WARNING sent to a client
#                     (an ANALYZE it may not run, a COMMIT outside a transaction), and the
#                     FATALs of a routine start or stop (connections refused while the
#                     server starts up or shuts down, sessions ended by a fast shutdown),
#                     and the ERRORs of a cancelled statement (a client's cancel, the
#                     stop signal reaching a running query, autovacuum giving way).
#
# DETAIL, HINT, CONTEXT, STATEMENT, QUERY and LOCATION lines, and the unprefixed lines of a
# message that spans several, go where the line they belong to went. A replica that cannot
# reach node 1 retries every 5 s; that line is written at most once a minute, with a count
# of the repeats not shown.
#
# Lines look like log_line_prefix '%m [%p] %q%u@%d ': "2026-10-17 16:46:09.404 UTC [5310]
# app@app ERROR:  ...", with no user@db for the server's own processes. Plain POSIX awk
# (mawk, gawk, busybox); every line is flushed as it is written.

BEGIN {
	last = "warn" # an unprefixed line before any prefixed one is the server failing to start
	quiet = 60
}

function out(dest, line) {
	if (dest == "warn") {
		print line > "/dev/stderr"
		fflush("/dev/stderr")
	} else if (dest == "info") {
		print line
		fflush()
	}
	# "drop": a repeat inside the quiet window, and its continuation lines.
}

function crash_log(msg) {
	return msg ~ /terminated by signal/ ||
		msg ~ /terminating any other active server processes/ ||
		msg ~ /database system was not properly shut down/ ||
		msg ~ /invalidating obsolete replication slot/
}

function routine_fatal(msg) {
	return msg ~ /^the database system is (starting up|shutting down|not yet accepting connections|not accepting connections|in recovery mode)/ ||
		msg ~ /due to administrator command$/
}

# The level a primary line is written at.
function classify(sev, msg, session) {
	if (sev == "PANIC")
		return "warn"
	if (sev == "FATAL")
		return routine_fatal(msg) ? "info" : "warn"
	if (sev == "ERROR") {
		# A replica making sure node 1 holds its slot, racing node 1 creating it.
		if (msg ~ /^replication slot "replica_[0-9]+" already exists/)
			return "info"
		# A statement cancelled on purpose: nothing went wrong.
		if (msg ~ /^canceling statement due to user request/ || msg ~ /^canceling autovacuum task/)
			return "info"
		return "warn"
	}
	if (sev == "WARNING") {
		if (msg ~ /must be vacuumed within/ || msg ~ /because of crash of another server process/)
			return "warn"
		return session ? "info" : "warn"
	}
	if (sev == "LOG")
		return crash_log(msg) ? "warn" : "info"
	return "info"
}

# Seconds into the line's day, and the day; a new day always ends a quiet window.
function stamp(line) {
	day = substr(line, 1, 10)
	return substr(line, 12, 2) * 3600 + substr(line, 15, 2) * 60 + substr(line, 18, 2)
}

# Writes the first of a repeating line, then at most one per quiet window, telling how
# many were not shown in between.
function limit(key, line,    t, note) {
	t = stamp(line)
	if (key in seen && seen_day[key] == day && t - seen[key] < quiet) {
		held[key]++
		return "drop"
	}
	note = ""
	if (held[key] > 0)
		note = " (and " held[key] " more like this not shown)"
	seen[key] = t
	seen_day[key] = day
	held[key] = 0
	pending = note
	return "warn"
}

{
	line = $0
	pending = ""
	if (!match(line, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9][^[]*\[[0-9]+\] /)) {
		out(last, line) # the next line of a message that spans several
		next
	}
	pid = substr(line, RSTART, RLENGTH)
	sub(/^.*\[/, "", pid)
	sub(/\] $/, "", pid)
	rest = substr(line, RLENGTH + 1)
	session = 0
	if (match(rest, /^[^ ]*@[^ ]* /)) {
		session = 1
		rest = substr(rest, RLENGTH + 1)
	}
	sev = ""
	msg = rest
	if (match(rest, /^[A-Z][A-Z0-9]*:  /)) {
		sev = substr(rest, 1, RLENGTH - 3)
		msg = substr(rest, RLENGTH + 1)
	}
	if (sev ~ /^(DETAIL|HINT|CONTEXT|STATEMENT|QUERY|LOCATION)$/) {
		last = (pid in level) ? level[pid] : last
		out(last, line)
		next
	}
	if (msg ~ /^could not connect to the primary server/)
		dest = limit("connect", line)
	else if (msg ~ /^could not start WAL streaming/)
		dest = limit("stream", line)
	else
		dest = classify(sev, msg, session)
	# Node 1 is back: say how many retries were not shown.
	shown = 0
	if (msg ~ /^started streaming WAL from primary/) {
		for (key in held) {
			shown += held[key]
			delete held[key]
			delete seen[key]
		}
	}
	# Remembered per process, for its DETAIL and STATEMENT lines; forgotten in bulk now
	# and then, since process ids are not reused soon.
	if (++remembered > 1000) {
		for (key in level)
			delete level[key]
		remembered = 0
	}
	level[pid] = dest
	last = dest
	out(dest, line pending)
	if (shown > 0)
		out("info", "postgres log: " shown " more retries before this were not shown")
}

END {
	for (key in held)
		if (held[key] > 0)
			out("info", "postgres log: " held[key] " more retries were not shown")
}
