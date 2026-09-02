#!/bin/sh
set -eu

fail() {
	echo "java install: $*" >&2
	exit 1
}

case "${APP_VERSION:-}" in
26.0.2_10 | 25.0.4_7 | 21.0.12_8 | 17.0.20_8 | 11.0.32_9 | 8u502-b07) ;;
*) fail "unsupported APP_VERSION: ${APP_VERSION:-<empty>}" ;;
esac
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

case "$(uname -m)" in
x86_64 | amd64) arch=x64 ;;
aarch64 | arm64) arch=aarch64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

case "$APP_VERSION" in
8u*-b*) release="jdk$APP_VERSION" ;;
*_*)
	version_base=${APP_VERSION%_*}
	build=${APP_VERSION##*_}
	release="jdk-$version_base+$build"
	;;
*) fail "unsupported Temurin version format: $APP_VERSION" ;;
esac

api=https://api.adoptium.net/v3
binary_url="$api/binary/version/$release/linux/$arch/jdk/hotspot/normal/eclipse?project=jdk"
checksum_url="$api/checksum/version/$release/linux/$arch/jdk/hotspot/normal/eclipse?project=jdk"
root=${JAVA_INSTALL_ROOT:-/opt/java}
bin_dir=${JAVA_BIN_DIR:-/usr/local/bin}
prefix="$root/$APP_VERSION"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

curl -fsSL "$binary_url" -o "$work/jdk.tar.gz"
expected=$(curl -fsSL "$checksum_url" | awk 'NR == 1 { print $1 }')
[ -n "$expected" ] || fail "Adoptium did not publish a checksum for $release"
actual=$(sha256sum "$work/jdk.tar.gz" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail "checksum verification failed for $release"

rm -rf "$prefix"
mkdir -p "$prefix"
tar -xzf "$work/jdk.tar.gz" --strip-components=1 -C "$prefix"
[ -x "$prefix/bin/java" ] || fail "java binary is missing from the archive"

mkdir -p "$bin_dir"
# Remove commands exposed by an older JDK when the selected JDK does not ship
# them. Only links into this app's versioned root are ours to remove.
for link in "$bin_dir"/*; do
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$root"/*/bin/*)
		name=${link##*/}
		[ -x "$prefix/bin/$name" ] || rm -f "$link"
		;;
	esac
done
for executable in "$prefix"/bin/*; do
	[ -x "$executable" ] || continue
	name=${executable##*/}
	ln -sfn "$executable" "$bin_dir/$name"
done
ln -sfn "$prefix" "$root/current"

version_output=$("$prefix/bin/java" -version 2>&1)
case "$APP_VERSION" in
8u*-b*)
	security=${APP_VERSION#8u}
	security=${security%%-*}
	expected_version="1.8.0_$security"
	;;
*) expected_version=${APP_VERSION%_*} ;;
esac
case "$version_output" in
*\""$expected_version\""*) printf '%s\n' "$version_output" >&2 ;;
*) fail "installed Java version does not match $APP_VERSION: $version_output" ;;
esac
