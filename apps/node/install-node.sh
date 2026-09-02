#!/bin/sh
set -eu

fail() {
	echo "node install: $*" >&2
	exit 1
}

[ -n "${APP_VERSION:-}" ] || fail "APP_VERSION is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

case "$(uname -m)" in
x86_64 | amd64) arch=x64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

version=${APP_VERSION#v}
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid APP_VERSION: $APP_VERSION" ;;
esac
asset="node-v$version-linux-$arch.tar.xz"
base="https://nodejs.org/dist/v$version"
root=${NODE_INSTALL_ROOT:-/opt/node}
bin_dir=${NODE_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

curl -fsSL "$base/$asset" -o "$work/$asset"
curl -fsSL "$base/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
expected=$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1 }' "$work/SHASUMS256.txt")
[ -n "$expected" ] || fail "checksum for $asset was not published"
actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

rm -rf "$prefix"
mkdir -p "$prefix"
tar -xJf "$work/$asset" --strip-components=1 -C "$prefix"

mkdir -p "$bin_dir"
for name in node npm npx corepack; do
	if [ -e "$prefix/bin/$name" ]; then
		ln -sfn "$prefix/bin/$name" "$bin_dir/$name"
	fi
done

actual_version=$("$prefix/bin/node" --version)
case "$actual_version" in
"v$version" | "v$version"-*) ;;
*) fail "installed version $actual_version does not match $version" ;;
esac
