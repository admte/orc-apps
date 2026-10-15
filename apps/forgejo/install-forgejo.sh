#!/bin/sh
set -eu

# Installs one Forgejo release into its own directory and exposes it through a symlink,
# the same shape cosign, snyk and mise use. Forgejo publishes bare executables, so there
# is nothing to unpack.
#
# Unlike every other package here, this one installs a *server*: it also creates the
# account the service runs as and the data directory the platform persists. The data
# directory is never initialised beyond its permissions — Forgejo's own first-run setup
# writes app.ini and the database, and on a node rebuilt from a baked image that work has
# already been done and must not be undone.

fail() {
	echo "forgejo install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

need curl
need mktemp
need useradd
need setpriv

[ "$(id -u)" -eq 0 ] || fail "must run as root"

case "$(uname -s)" in
Linux) ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
x86_64 | amd64) platform=linux-amd64 ;;
aarch64 | arm64) platform=linux-arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

api=https://codeberg.org/api/v1/repos/forgejo/forgejo/releases

version=${APP_VERSION:-}
if [ -z "$version" ]; then
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag,
	# so the newest release is asked of the project rather than guessed.
	echo "forgejo install: no version was requested; taking the newest release" >&2
	latest=$(curl -fsSL "$api/latest") ||
		fail "could not read the newest release from Codeberg"
	version=$(printf '%s' "$latest" |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' |
		head -1)
	[ -n "$version" ] || fail "the release response names no version"
	echo "forgejo install: newest release is $version" >&2
fi
version=${version#v}

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

root=${FORGEJO_INSTALL_ROOT:-/opt/forgejo}
bin_dir=${FORGEJO_BIN_DIR:-/usr/local/bin}
data_dir=${FORGEJO_DATA_DIR:-/var/lib/forgejo}
service_user=${FORGEJO_SERVICE_USER:-forgejo}
prefix="$root/$version"
link="$bin_dir/forgejo"

work=$(mktemp -d)
tmp_link="$bin_dir/.forgejo.orc.$$"
trap 'rm -rf "$work" "$tmp_link"' EXIT HUP INT TERM

# Repoints the exposure symlink atomically, so a running service restarted mid-switch
# never finds a missing binary.
expose() {
	mkdir -p "$bin_dir"
	[ ! -d "$link" ] || fail "$link is a directory"
	rm -f "$tmp_link"
	ln -s "$prefix/forgejo" "$tmp_link"
	mv -f "$tmp_link" "$link"
}

reported_version() {
	"$1" --version 2>/dev/null || return 1
}

# The account the service runs as. No home directory and no login: the start script
# points HOME at the data directory, which this account owns.
ensure_service_user() {
	if id "$service_user" >/dev/null 2>&1; then
		return 0
	fi
	useradd -r -U -M "$service_user"
	id "$service_user" >/dev/null 2>&1 || fail "failed to create service user $service_user"
}

# Only the directories and their ownership. Nothing inside is created, moved or removed:
# on a node rebuilt from a baked image, or on one whose persisted volume was restored,
# this tree already holds a configured instance.
#
# This is NOT what the running service relies on. /var/lib/forgejo is a declared persisted
# path, and install runs while the pool image is baked, so what it creates here is masked
# by the volume the platform mounts over that path on a rebuilt node. start-forgejo.sh
# ensures the same layout on every boot, after the volume is in place; this call only
# covers an install with no persisted volume behind it, such as the manual test.
ensure_data_dir() {
	mkdir -p "$data_dir/custom/conf" "$data_dir/data" "$data_dir/log"
	chown "$service_user:$service_user" \
		"$data_dir" "$data_dir/custom" "$data_dir/custom/conf" "$data_dir/data" "$data_dir/log"
	chmod 0750 "$data_dir"
}

# Already here? The pool image is baked straight after this phase and the node is then
# rebuilt from that image, which runs this phase again on a disk that already carries the
# binary.
if [ -x "$prefix/forgejo" ] && reported=$(reported_version "$prefix/forgejo"); then
	case "$reported" in
	*"$version"*)
		expose
		ensure_service_user
		ensure_data_dir
		echo "forgejo install: forgejo $version is already installed" >&2
		exit 0
		;;
	esac
fi

# The tag carries a leading "v"; the asset name does not.
asset="forgejo-$version-$platform"
sums="$asset.sha256"
base="https://codeberg.org/forgejo/forgejo/releases/download/v$version"

echo "forgejo install: downloading $asset" >&2
curl -fsSL "$base/$asset" -o "$work/$asset" || fail "could not download $asset"
curl -fsSL "$base/$sums" -o "$work/$sums" || fail "could not download $sums"

# Matched on the whole name with awk's exact field comparison: the release publishes an
# .xz of the same build whose checksum file sits beside this one.
expected=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$work/$sums")
[ -n "$expected" ] || fail "checksum for $asset was not published"

if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
	actual=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
else
	fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

# Claim only this version's own subtree: /opt/forgejo may already hold other versions.
mkdir -p "$prefix"
install -m 0755 "$work/$asset" "$prefix/forgejo"

expose
ensure_service_user
ensure_data_dir

reported=$(reported_version "$prefix/forgejo") || fail "forgejo does not run on this node"
case "$reported" in
*"$version"*) ;;
*) fail "installed version '$reported' does not match $version" ;;
esac

case "${APP_PERSIST_STATE:-}" in
empty | '')
	echo "forgejo install: the data directory is empty; Forgejo's own setup page will run on first start" >&2
	;;
*)
	echo "forgejo install: the data directory already holds an instance (${APP_PERSIST_STATE}); leaving it untouched" >&2
	;;
esac

echo "forgejo install: forgejo $version installed at $prefix, data at $data_dir" >&2
