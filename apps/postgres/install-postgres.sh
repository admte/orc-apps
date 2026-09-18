#!/bin/sh
set -eu

# Install phase: PostgreSQL 17 server and client from the PGDG apt repository, and
# nothing else. No cluster is created here and no secret is written: a pool bake runs
# install alone and snapshots the disk, so anything written here is shared by every
# clone of that image. initdb, the application role, and a replica's seed are the
# start phase's, which runs on the node that actually holds the slot.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_PHASE=install
# shellcheck source=postgres-common.sh
. "$SCRIPT_DIR/postgres-common.sh"

# Already installed: nothing to do. Keeps pool-image bakes idempotent.
if [ -x "$PG_BIN/postgres" ]; then
	"$PG_BIN/postgres" --version >&2
	exit 0
fi

[ "$(id -u)" -eq 0 ] || pg_fail "must run as root"
command -v apt-get >/dev/null 2>&1 || pg_fail "unsupported distribution: apt-get not found"
pg_need systemctl

export DEBIAN_FRONTEND=noninteractive

distro=debian
codename=""
if [ -r /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	[ -n "${ID:-}" ] && distro=$ID
	codename=${VERSION_CODENAME:-}
fi
[ -n "$codename" ] || pg_fail "could not determine the release codename from /etc/os-release"
arch=$(dpkg --print-architecture)

pg_note "installing prerequisites (ca-certificates, curl, postgresql-common)"
apt-get update -qq
apt-get install -y -qq ca-certificates curl postgresql-common

# The distro's postgresql-common creates and enables a "main" cluster the moment the
# server package lands. This app owns its clusters, so that is switched off before the
# server package is installed.
pg_note "disabling the automatic main cluster"
mkdir -p /etc/postgresql-common
if grep -q '^#\?create_main_cluster' /etc/postgresql-common/createcluster.conf 2>/dev/null; then
	sed -i 's/^#\?create_main_cluster.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf
else
	echo 'create_main_cluster = false' >>/etc/postgresql-common/createcluster.conf
fi

pg_note "installing the PGDG signing key"
mkdir -p /etc/apt/keyrings
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /etc/apt/keyrings/pgdg.asc
chmod a+r /etc/apt/keyrings/pgdg.asc

# Writes the PGDG repo for one codename and tries to install from it. A failure returns
# non-zero so the caller can retry with another codename rather than aborting.
install_from_repo() {
	repo_codename=$1
	pg_note "configuring the PGDG apt repo for $distro/$repo_codename ($arch)"
	printf 'deb [arch=%s signed-by=/etc/apt/keyrings/pgdg.asc] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' \
		"$arch" "$repo_codename" >/etc/apt/sources.list.d/pgdg.list
	apt-get update -qq || return 1
	# confold keeps the createcluster.conf edit above when PGDG's newer
	# postgresql-common replaces the distro's.
	apt-get install -y -qq -o Dpkg::Options::=--force-confold \
		"postgresql-$PG_MAJOR" "postgresql-client-$PG_MAJOR" || return 1
}

# A release newer than PGDG's coverage falls back to the previous LTS / stable
# codename, whose packages are compatible.
if ! install_from_repo "$codename"; then
	case "$distro" in
	ubuntu) fallback=noble ;;
	*) fallback=bookworm ;;
	esac
	pg_note "PGDG repo for '$codename' unavailable; falling back to '$fallback'"
	install_from_repo "$fallback" || pg_fail "postgresql-$PG_MAJOR installation failed for both '$codename' and '$fallback'"
fi

[ -x "$PG_BIN/postgres" ] || pg_fail "postgresql-$PG_MAJOR installed but $PG_BIN/postgres is missing"
id "$PG_OS_USER" >/dev/null 2>&1 || pg_fail "the $PG_OS_USER account was not created by the package"

# The packaged umbrella unit must never start a cluster behind this app's back.
systemctl disable --now postgresql >/dev/null 2>&1 || true

# Directories the start phase fills. The persisted root is grafted by the platform
# before install and is left alone here: what goes into it is slot 1's decision.
mkdir -p "$APP_ROOT/replica" "$TLS_DIR"
chown "$PG_OS_USER:$PG_OS_USER" "$APP_ROOT/replica" "$TLS_DIR"
chmod 0700 "$APP_ROOT/replica" "$TLS_DIR"

"$PG_BIN/postgres" --version >&2
pg_note "complete bin=$PG_BIN"
