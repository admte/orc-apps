#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-java.sh [--version=VERSION] [--install-root=DIR] [--bin-dir=DIR]

Installs one Eclipse Temurin JDK release from Adoptium under its own directory
and links its commands onto PATH. Without --version it installs the newest
release built for this machine.

  --version=VERSION   JDK release to install, e.g. 21.0.4 (default: newest)
  --install-root=DIR  directory each release is unpacked under (default: /opt/java)
  --bin-dir=DIR       where the JDK commands are linked (default: /usr/local/bin)
  --help              show this help
USAGE
}

fail() {
	echo "java install: $*" >&2
	exit 1
}

usage_error() {
	echo "java install: $*" >&2
	usage >&2
	exit 2
}

version=
root=/opt/java
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--version=*) version=${arg#--version=} ;;
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
aarch64 | arm64) arch=aarch64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

api=https://api.adoptium.net/v3
selector="os=linux&architecture=$arch&image_type=jdk&jvm_impl=hotspot&heap_size=normal&vendor=eclipse&project=jdk"

if [ -z "$version" ]; then
	# The newest release with a build for this machine, as major.minor.security.
	version=$(curl -fsSL \
		"$api/info/release_versions?release_type=ga&$selector&page_size=1&sort_method=DEFAULT&sort_order=DESC" |
		tr -d ' \t\n' |
		sed -n 's/.*"semver":"\([0-9]*\.[0-9]*\.[0-9]*\)[+"].*/\1/p') ||
		fail "could not determine the newest release for linux/$arch"
	[ -n "$version" ] || fail "could not determine the newest release for linux/$arch"
fi
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

# --version is the release; [X,X.1) resolves its newest build for this machine.
# Adoptium answers 404 when it has no build of that release for this platform.
range="%5B$version,$version.1%29"
release=$(curl -fsSL \
	"$api/info/release_names?release_type=ga&version=$range&$selector&page_size=1&sort_method=DEFAULT&sort_order=DESC" 2>/dev/null |
	tr -d ' \t\n' |
	sed -n 's/.*"releases":\["\([^"]*\)".*/\1/p') || true
[ -n "$release" ] || fail "Adoptium publishes no build of $version for linux/$arch"
case "$release" in
jdk-* | jdk8u*) ;;
*) fail "unexpected release name from Adoptium: $release" ;;
esac

binary_url="$api/binary/version/$release/linux/$arch/jdk/hotspot/normal/eclipse?project=jdk"
checksum_url="$api/checksum/version/$release/linux/$arch/jdk/hotspot/normal/eclipse?project=jdk"
prefix="$root/$version"
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

# java -version reports the release's own version: 27 for jdk-27+35,
# 27.0.1.0.2 for jdk-27.0.1.0.2+1, and 1.8.0_<security> for Java 8.
case "$release" in
jdk8u*)
	security=${release#jdk8u}
	security=${security%%-*}
	expected_version="1.8.0_$security"
	;;
*)
	expected_version=${release#jdk-}
	expected_version=${expected_version%%+*}
	;;
esac
version_output=$("$prefix/bin/java" -version 2>&1)
case "$version_output" in
*\""$expected_version\""*) printf '%s\n' "$version_output" >&2 ;;
*) fail "installed Java version does not match $version: $version_output" ;;
esac
