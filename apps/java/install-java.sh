#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-java.sh [--version=VERSION] [--install-root=DIR] [--bin-dir=DIR]

Installs one Eclipse Temurin JDK release from Adoptium under its own directory
and links its commands onto PATH.

  --version=VERSION   JDK release to install, e.g. 21.0.4
                      (default: the newest release Adoptium publishes)
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

if [ -z "$version" ]; then
	# The version arrives empty when the request resolved to the implicit
	# `default` tag. Adoptium reports semver as X.Y.Z+build, but some releases
	# carry more components, e.g. 27.0.1.0.2+1. Take the newest that is X.Y.Z
	# and nothing more: that is what artifact.yaml offers as a version, and
	# what the [X,X.1) range below resolves.
	curl -fsSL \
		"$api/info/release_versions?release_type=ga&vendor=eclipse&os=linux&architecture=$arch&image_type=jdk&sort_method=DEFAULT&sort_order=DESC&page_size=50" \
		-o "$work/versions.json" ||
		fail "could not read the newest release from Adoptium"
	version=$(grep -oE '"semver"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\+' \
		"$work/versions.json" | head -1 | sed 's/.*"//; s/+$//')
	[ -n "$version" ] || fail "the release list names no version"
	echo "java install: no version was requested; taking the newest release, $version"
fi

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

# --version is the release; [X,X.1) resolves its newest build for this machine.
range="%5B$version,$version.1%29"
release=$(curl -fsSL \
	"$api/info/release_names?release_type=ga&version=$range&$selector&page_size=1&sort_method=DEFAULT&sort_order=DESC" |
	tr -d ' \t\n' |
	sed -n 's/.*"releases":\["\([^"]*\)".*/\1/p')
[ -n "$release" ] || fail "Adoptium publishes no $version release for linux/$arch"
case "$release" in
jdk-* | jdk8u*) ;;
*) fail "unexpected release name from Adoptium: $release" ;;
esac

case "$release" in
jdk8u*)
	# Java 8 reports 1.8.0_<security>.
	security=${release#jdk8u}
	security=${security%%-*}
	expected_version="1.8.0_$security"
	;;
*)
	# A request for 27.0.1 is answered with jdk-27.0.1.0.2+1, and that JDK
	# reports 27.0.1.0.2, so take the expected version from the release name
	# rather than from what was asked for.
	expected_version=${release#jdk-}
	expected_version=${expected_version%%+*}
	;;
esac

binary_url="$api/binary/version/$release/linux/$arch/jdk/hotspot/normal/eclipse?project=jdk"
checksum_url="$api/checksum/version/$release/linux/$arch/jdk/hotspot/normal/eclipse?project=jdk"
prefix="$root/$version"

expose() {
	mkdir -p "$bin_dir"
	# Remove commands exposed by an older JDK when the selected JDK does not
	# ship them. Only links into this app's versioned root are ours to remove.
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
}

# The pool image is baked straight after this phase, and every node is rebuilt
# from that image. Without this check each node downloads and unpacks a release
# the disk already carries.
if reported=$("$prefix/bin/java" -version 2>&1); then
	case "$reported" in
	*\""$expected_version"\"*)
		expose
		echo "java install: java $version is already installed"
		exit 0
		;;
	esac
fi

curl -fsSL "$binary_url" -o "$work/jdk.tar.gz"
expected=$(curl -fsSL "$checksum_url" | awk 'NR == 1 { print $1 }')
[ -n "$expected" ] || fail "Adoptium did not publish a checksum for $release"
actual=$(sha256sum "$work/jdk.tar.gz" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail "checksum verification failed for $release"

rm -rf "$prefix"
mkdir -p "$prefix"
tar -xzf "$work/jdk.tar.gz" --strip-components=1 -C "$prefix"
[ -x "$prefix/bin/java" ] || fail "java binary is missing from the archive"

expose

version_output=$("$prefix/bin/java" -version 2>&1)
case "$version_output" in
*\""$expected_version\""*) printf '%s\n' "$version_output" ;;
*) fail "installed Java version does not match $version: $version_output" ;;
esac
