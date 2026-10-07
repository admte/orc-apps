#!/bin/sh
set -eu

# Installs the SDK command-line tools and accepts the licences, so that a build
# can ask sdkmanager for the components it pins without anyone answering a
# prompt. The components themselves are the build's business: they are named in
# its Gradle files and land in the same shared tree.

# Lower case, like every other variable here: a shell script has no namespace of
# its own, and REPO or INDEX is a name that can arrive from the environment.
repo=${ANDROID_SDK_REPO:-https://dl.google.com/android/repository}
index=${ANDROID_SDK_INDEX:-repository2-3.xml}
# Used only when the node carries no Java of its own. cmdline-tools is a Java
# program; 21 is the current long-term release.
jdk_feature=${ANDROID_SDK_JDK_FEATURE:-21}
# cmdline-tools is compiled for 17; anything older cannot run it at all.
jdk_minimum=${ANDROID_SDK_JDK_MINIMUM:-17}
adoptium=${ANDROID_SDK_ADOPTIUM_API:-https://api.adoptium.net/v3}

fail() {
	echo "android-sdk install: $*" >&2
	exit 1
}

note() {
	echo "android-sdk install: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

case "$(uname -s)" in
Linux) ;;
*) fail "supported on Linux only: $(uname -s)" ;;
esac
case "$(uname -m)" in
x86_64 | amd64) ;;
*) fail "the Android SDK publishes x86-64 builds only for Linux; this node is $(uname -m)" ;;
esac
[ "$(id -u)" -eq 0 ] || fail "must run as root: the SDK is installed system-wide"

need awk
need curl
need find
need mktemp
need python3
need sed
need sha1sum
need sha256sum
need unzip

sdk_root=${ANDROID_SDK_INSTALL_ROOT:-/opt/android-sdk}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; exit 1' HUP INT TERM

# sdkmanager is a Java program. If the node already carries a JDK — from the
# `java` app or from its image — that one is used. Otherwise a copy is fetched
# into the temporary directory and thrown away with it, so the app works when it
# is the only one an operator picked and does not depend on install order.
#
# A build needs a JDK of its own afterwards; that is not this phase's business,
# but it is why the README says so.
# The java sdkmanager will actually run. Its launcher prefers JAVA_HOME and only
# falls back to PATH, so checking the version of whatever PATH happens to hold
# would pass a node whose JAVA_HOME points at an older JDK.
java_binary() {
	if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
		printf '%s' "$JAVA_HOME/bin/java"
	elif command -v java >/dev/null 2>&1; then
		command -v java
	fi
}

# The major version out of `java -version`. Not from the first line: a node with
# JAVA_TOOL_OPTIONS set prints a "Picked up ..." line before it. Java 8 reports
# 1.8.0_x, so this yields 1 and is correctly rejected.
java_major() {
	"$1" -version 2>&1 |
		sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' |
		head -1
}

ensure_java() {
	existing=$(java_binary)
	if [ -n "$existing" ]; then
		major=$(java_major "$existing")
		if [ -n "$major" ] && [ "$major" -ge "$jdk_minimum" ] 2>/dev/null; then
			note "using the Java already on this node: $existing ($("$existing" -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -1))"
			return 0
		fi
		note "the Java on this node is too old for the command-line tools: $existing is ${major:-unreadable}, need $jdk_minimum"
	fi
	need tar
	note "fetching a temporary JDK $jdk_feature for sdkmanager"

	selector="os=linux&architecture=x64&image_type=jdk&jvm_impl=hotspot&heap_size=normal&vendor=eclipse&project=jdk"
	range="%5B$jdk_feature,$((jdk_feature + 1))%29"
	release=$(curl -fsSL \
		"$adoptium/info/release_names?release_type=ga&version=$range&$selector&page_size=1&sort_method=DEFAULT&sort_order=DESC" |
		tr -d ' \t\n' |
		sed -n 's/.*"releases":\["\([^"]*\)".*/\1/p')
	[ -n "$release" ] || fail "Adoptium publishes no JDK $jdk_feature release for linux/x64"
	case "$release" in
	jdk-*) ;;
	*) fail "unexpected release name from Adoptium: $release" ;;
	esac

	curl -fsSL "$adoptium/binary/version/$release/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" \
		-o "$work/jdk.tar.gz" || fail "could not download the temporary JDK $release"
	# The endpoint serves a `sha256sum` line — digest, spaces, filename — so the
	# first field is the digest, and its shape is checked before it is trusted.
	expected=$(curl -fsSL "$adoptium/checksum/version/$release/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" |
		awk 'NR == 1 { print $1 }')
	printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$' ||
		fail "Adoptium published no usable checksum for $release"
	actual=$(sha256sum "$work/jdk.tar.gz" | awk '{ print $1 }')
	[ "$actual" = "$expected" ] || fail "checksum verification failed for the temporary JDK $release"

	mkdir -p "$work/jdk"
	tar -xzf "$work/jdk.tar.gz" --strip-components=1 -C "$work/jdk" ||
		fail "could not unpack the temporary JDK"
	JAVA_HOME="$work/jdk"
	export JAVA_HOME
	PATH="$JAVA_HOME/bin:$PATH"
	export PATH
	[ -x "$JAVA_HOME/bin/java" ] || fail "the temporary JDK does not provide java"
	note "temporary JDK $release will be removed when this phase ends"
}

# The archive Google currently publishes, read from the index sdkmanager itself
# uses. The build number lives in the filename and changes, so there is no
# stable URL to hard-code — and the checksum has to come from the same place as
# the URL to be worth anything.
read_archive() {
	python3 - "$work/index.xml" <<'PY'
import sys, xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except ET.ParseError as err:
    sys.exit("could not parse the repository index: %s" % err)


def tag(element):
    # The document declares namespaces; the elements below are unqualified in
    # practice, but strip a prefix if one ever appears.
    return element.tag.rsplit("}", 1)[-1]


def find(parent, name):
    for child in parent:
        if tag(child) == name:
            return child
    return None


for package in root.iter():
    if tag(package) != "remotePackage":
        continue
    if package.get("path") != "cmdline-tools;latest":
        continue
    archives = find(package, "archives")
    if archives is None:
        continue
    for archive in archives:
        if tag(archive) != "archive":
            continue
        host = find(archive, "host-os")
        if host is None or (host.text or "").strip() != "linux":
            continue
        arch = find(archive, "host-arch")
        if arch is not None and (arch.text or "").strip() not in ("", "x64"):
            continue
        complete = find(archive, "complete")
        if complete is None:
            continue
        url = find(complete, "url")
        checksum = find(complete, "checksum")
        if url is None or checksum is None:
            continue
        print((url.text or "").strip())
        print((checksum.get("type") or "sha1").strip().lower())
        print((checksum.text or "").strip())
        raise SystemExit(0)

sys.exit("the repository index lists no linux build of cmdline-tools;latest")
PY
}

ensure_java

note "reading the SDK repository index"
curl -fsSL "$repo/$index" -o "$work/index.xml" ||
	fail "could not read the SDK repository index $repo/$index"

archive=$(read_archive) ||
	fail "could not find a linux build of cmdline-tools in the repository index"
asset=$(printf '%s\n' "$archive" | sed -n 1p)
digest_type=$(printf '%s\n' "$archive" | sed -n 2p)
expected=$(printf '%s\n' "$archive" | sed -n 3p)
[ -n "$asset" ] && [ -n "$expected" ] ||
	fail "the repository index gave no archive for linux"
[ "$digest_type" = sha1 ] ||
	fail "the repository index publishes a $digest_type checksum, which this script does not verify"

note "downloading $asset"
curl -fsSL "$repo/$asset" -o "$work/$asset" || fail "could not download $asset"
actual=$(sha1sum "$work/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

# The archive unpacks to a `cmdline-tools` directory, and sdkmanager insists on
# living at <sdk>/cmdline-tools/latest/bin — the contents move one level down.
unzip -q "$work/$asset" -d "$work/unpacked" || fail "could not unpack $asset"
[ -f "$work/unpacked/cmdline-tools/bin/sdkmanager" ] ||
	fail "$asset does not contain cmdline-tools/bin/sdkmanager"
chmod +x "$work/unpacked/cmdline-tools/bin/"* 2>/dev/null || true

mkdir -p "$sdk_root/cmdline-tools"
rm -rf "$sdk_root/cmdline-tools/latest.new"
mv "$work/unpacked/cmdline-tools" "$sdk_root/cmdline-tools/latest.new" ||
	fail "could not stage the command-line tools under $sdk_root"
rm -rf "$sdk_root/cmdline-tools/latest"
mv "$sdk_root/cmdline-tools/latest.new" "$sdk_root/cmdline-tools/latest" ||
	fail "could not install the command-line tools under $sdk_root"

sdkmanager="$sdk_root/cmdline-tools/latest/bin/sdkmanager"
[ -x "$sdkmanager" ] || fail "sdkmanager is missing after unpacking: $sdkmanager"

# Every licence, accepted once, as root. This is the half a build cannot do: the
# prompt is interactive and the answers are written into a root-owned directory.
note "accepting the SDK licences"
yes | "$sdkmanager" --sdk_root="$sdk_root" --licenses >/dev/null ||
	fail "could not accept the SDK licences"

# `--licenses` reports success and writes nothing when it cannot reach the
# repository to enumerate them, and the first build is then stopped by the very
# prompt this phase exists to answer. So the result is checked, not assumed.
licence_dir="$sdk_root/licenses"
accepted=$(find "$licence_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
[ "$accepted" -gt 0 ] ||
	fail "no licences were written to $licence_dir; the tools could not reach the SDK repository"
note "$accepted licences accepted in $licence_dir"

# The tools and the accepted licences stay root-owned and read-only to everyone
# else. The tree around them is opened so a build can install the components it
# pins; the sticky bit keeps a build from removing the entries at this level,
# including cmdline-tools and licenses. It says nothing about what happens
# deeper: a component directory belongs to the build that created it, which is
# why the README asks that builds on a pool share one account.
chmod 1777 "$sdk_root" || fail "could not set permissions on $sdk_root"

if ! output=$("$sdkmanager" --sdk_root="$sdk_root" --version 2>&1); then
	fail "sdkmanager does not run after installation: $(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)"
fi
version=$(printf '%s\n' "$output" | tail -1)
note "command-line tools $version installed at $sdk_root"
note "set ANDROID_HOME=$sdk_root in the build to use them"
