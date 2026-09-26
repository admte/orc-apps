#!/bin/sh
set -eu

# Node line used only when the node has no Node.js of its own. Playwright needs
# 22 or newer; this is the oldest line it supports, so the temporary copy is the
# least surprising thing that can work.
NODE_LINE=${NODE_LINE:-latest-v22.x}
NODE_DIST=${NODE_DIST:-https://nodejs.org/dist}

fail() {
	echo "playwright install: $*" >&2
	exit 1
}

note() {
	echo "playwright install: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

case "$(uname -s)" in
Linux) ;;
*) fail "supported on Linux only: $(uname -s)" ;;
esac

# `playwright install-deps` knows only Debian and Ubuntu, so anything else is a
# loud failure rather than a half-prepared node.
[ -r /etc/os-release ] || fail "/etc/os-release is not readable"
# shellcheck disable=SC1091
. /etc/os-release
debian_like=0
for id in ${ID:-} ${ID_LIKE:-}; do
	case "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')" in
	debian | ubuntu) debian_like=1 ;;
	esac
done
[ "$debian_like" -eq 1 ] ||
	fail "Playwright supports Debian and Ubuntu only; this node is id=${ID:-unknown} id_like=${ID_LIKE:-}"

[ "$(id -u)" -eq 0 ] || fail "must run as root: these are system packages"
need apt-get
need curl

case "$(uname -m)" in
x86_64 | amd64) arch=x64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; exit 1' HUP INT TERM

# Playwright's installer is Node software, so something has to run it. If the
# node already carries Node.js, that. Otherwise a copy is fetched into the
# temporary directory and thrown away with it — the app must work when it is the
# only one an operator picked, and nothing orders it after another app.
ensure_node() {
	if command -v npx >/dev/null 2>&1; then
		note "using the Node.js already on this node: $(node --version 2>/dev/null || echo unknown)"
		return 0
	fi
	need tar
	note "no Node.js on this node; fetching a temporary one for Playwright's installer"

	curl -fsSL "$NODE_DIST/$NODE_LINE/SHASUMS256.txt" -o "$work/SHASUMS256.txt" ||
		fail "could not read the Node.js checksums from $NODE_DIST/$NODE_LINE"
	asset=$(awk -v s="-linux-$arch.tar.xz" '
		substr($2, 1, 6) == "node-v" && index($2, s) { print $2; exit }
	' "$work/SHASUMS256.txt")
	[ -n "$asset" ] || fail "no Node.js build for linux-$arch in $NODE_LINE"

	curl -fsSL "$NODE_DIST/$NODE_LINE/$asset" -o "$work/$asset" ||
		fail "could not download $asset"
	expected=$(awk -v a="$asset" '$2 == a { print $1; exit }' "$work/SHASUMS256.txt")
	[ -n "$expected" ] || fail "checksum for $asset was not published"
	actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
	[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

	tar -xJf "$work/$asset" -C "$work" || fail "could not unpack $asset"
	PATH="$work/${asset%.tar.xz}/bin:$PATH"
	export PATH
	command -v npx >/dev/null 2>&1 || fail "the temporary Node.js does not provide npx"
	note "temporary Node.js $(node --version) will be removed when this phase ends"
}

ensure_node

note "installing the browser dependencies through Playwright dist=${ID:-unknown} ${VERSION_ID:-}"
DEBIAN_FRONTEND=noninteractive npx --yes playwright install-deps ||
	fail "could not install the browser dependencies; see the apt output above"

# A cache the jobs share, so the browsers of a given Playwright version are
# downloaded once on this node rather than once per job. Nothing is put here
# now: Playwright stores each version's builds in its own subdirectory, so the
# first job of a version fills it and the rest read it. Which version that is
# stays the job's business.
#
# 1777, the mode /tmp carries: any job may add a version, and the sticky bit
# keeps it from removing a directory another job created.
cache_dir=${PLAYWRIGHT_CACHE_DIR:-/usr/local/share/ms-playwright}
mkdir -p "$cache_dir" || fail "could not create the browser cache at $cache_dir"
chmod 1777 "$cache_dir" || fail "could not set permissions on $cache_dir"

note "the node can run Playwright browsers"
note "shared browser cache: $cache_dir — set PLAYWRIGHT_BROWSERS_PATH to it in the job to reuse downloads"
