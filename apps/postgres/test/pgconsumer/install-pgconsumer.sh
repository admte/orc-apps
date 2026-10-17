#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive
if ! command -v psql >/dev/null 2>&1; then
	apt-get update -qq
	apt-get install -y -qq postgresql-client openssl >/dev/null
fi
echo "pgconsumer install: $(psql --version)"
