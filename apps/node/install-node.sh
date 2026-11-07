#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-node.sh [--version=VERSION] [--install-root=DIR] [--bin-dir=DIR]

Installs one Node.js release under its own directory and links node, npm, npx
and corepack onto PATH.

  --version=VERSION   Node.js release to install, e.g. 20.17.0
                      (default: the newest release nodejs.org publishes)
  --install-root=DIR  directory each release is unpacked under (default: /opt/node)
  --bin-dir=DIR       where the commands are linked (default: /usr/local/bin)
  --help              show this help
USAGE
}

fail() {
	echo "node install: $*" >&2
	exit 1
}

usage_error() {
	echo "node install: $*" >&2
	usage >&2
	exit 2
}

requested=
root=/opt/node
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--version=*) requested=${arg#--version=} ;;
	--install-root=*) root=${arg#--install-root=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$root" ] || usage_error "--install-root must not be empty"
[ -n "$bin_dir" ] || usage_error "--bin-dir must not be empty"

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

case "$(uname -m)" in
x86_64 | amd64) arch=x64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

if [ -z "$requested" ]; then
	# The version arrives empty when the request resolved to the implicit
	# `default` tag. index.json lists the releases, newest first, and carries
	# prereleases too, so take the newest that is x.y.z and nothing more.
	curl -fsSL https://nodejs.org/dist/index.json -o "$work/index.json" ||
		fail "could not read the newest release from nodejs.org"
	requested=$(grep -o \
		'"version"[[:space:]]*:[[:space:]]*"v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' \
		"$work/index.json" | head -1 | sed 's/.*"v//; s/"$//')
	[ -n "$requested" ] || fail "the release list names no final version"
	echo "node install: no version was requested; taking the newest release, $requested"
fi

version=${requested#v}
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $requested" ;;
esac
asset="node-v$version-linux-$arch.tar.xz"
base="https://nodejs.org/dist/v$version"
prefix="$root/$version"

# The node binary links libatomic.so.1, which the Ubuntu 24.04, Debian 12 and
# AlmaLinux 9/10 base images do not carry. Install it here, so the pool image is
# baked with it rather than failing at first use.
ensure_libatomic() {
	if "$prefix/bin/node" --version >/dev/null 2>&1; then
		return 0
	fi
	if command -v apt-get >/dev/null 2>&1; then
		if DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update -qq &&
			DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
				apt-get install -y -qq libatomic1; then
			return 0
		fi
	elif command -v dnf >/dev/null 2>&1; then
		if dnf install -y -q libatomic; then
			return 0
		fi
	elif command -v yum >/dev/null 2>&1; then
		if yum install -y -q libatomic; then
			return 0
		fi
	fi
	fail "node $version needs libatomic.so.1; install libatomic1 (Debian, Ubuntu) or libatomic (RHEL family) and run the install again"
}

expose() {
	mkdir -p "$bin_dir"
	for name in node npm npx corepack; do
		if [ -e "$prefix/bin/$name" ]; then
			ln -sfn "$prefix/bin/$name" "$bin_dir/$name"
		fi
	done
}

# The pool image is baked straight after this phase. Should a node rebuilt from
# that image run the phase again, this keeps it from downloading and unpacking a
# release the disk already carries. One that runs has its libatomic already.
if reported=$("$prefix/bin/node" --version 2>/dev/null); then
	case "$reported" in
	"v$version" | "v$version"-*)
		expose
		echo "node install: node $version is already installed"
		exit 0
		;;
	esac
fi

curl -fsSL "$base/$asset" -o "$work/$asset"
curl -fsSL "$base/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
expected=$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1 }' "$work/SHASUMS256.txt")
[ -n "$expected" ] || fail "checksum for $asset was not published"
actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

rm -rf "$prefix"
mkdir -p "$prefix"
tar -xJf "$work/$asset" --strip-components=1 -C "$prefix"

ensure_libatomic

expose

actual_version=$("$prefix/bin/node" --version)
case "$actual_version" in
"v$version" | "v$version"-*) ;;
*) fail "installed version $actual_version does not match $version" ;;
esac
