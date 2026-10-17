#!/bin/sh
# TEST ONLY. Every 15 s: select 1 against the handed writer name, verify-full against the
# handed ca.bundle. OK lines go to stdout, failures to stderr. The status file holds the
# last result, the handed names and the bundle's subjects.
set -u
DB_NAME=${DB_NAME:-app}
DB_USER=${DB_USER:-app}
STATUS=/var/lib/pgconsumer/status
mkdir -p /var/lib/pgconsumer
started=$(date -u +%FT%TZ)
subjects=$(awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{printf "%s", c | "openssl x509 -noout -subject -issuer -enddate"; close("openssl x509 -noout -subject -issuer -enddate")}' "$CA_FILE" 2>&1)
echo "pgconsumer: started $started writer=$WRITER peers=$(tr '\n' ' ' <"$PEERS_FILE") bundle_certs=$(grep -c 'BEGIN CERT' "$CA_FILE")"
while :; do
	now=$(date -u +%FT%TZ)
	out=$(PGPASSWORD=$(cat "$DB_PASSWORD_FILE") PGCONNECT_TIMEOUT=8 psql -X -tA \
		"host=$WRITER sslmode=verify-full sslrootcert=$CA_FILE dbname=$DB_NAME user=$DB_USER" \
		-c 'select 1' 2>&1)
	rc=$?
	if [ $rc -eq 0 ] && [ "$out" = 1 ]; then
		result="OK"
		echo "pgconsumer: $now OK select 1 via $WRITER"
	else
		result="FAIL rc=$rc $(printf '%s' "$out" | tr '\n' ' ')"
		echo "pgconsumer: $now FAIL via $WRITER: $result" >&2
	fi
	{
		echo "time=$now"
		echo "started=$started"
		echo "result=$result"
		echo "writer=$WRITER"
		echo "peers=$(tr '\n' ' ' <"$PEERS_FILE")"
		echo "bundle_certs=$(grep -c 'BEGIN CERT' "$CA_FILE")"
		echo "bundle:"
		echo "$subjects"
	} >"$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
	sleep 15
done
