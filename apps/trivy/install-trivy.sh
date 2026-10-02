#!/bin/sh
set -eu

# Installs one Trivy release into its own directory and exposes it through a symlink,
# the same shape go, java, node and terraform use.

fail() {
	echo "trivy install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

need curl
need tar
need mktemp

case "$(uname -s)" in
Linux) ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac

# The project's own naming, taken from its checksums file: "Linux" capitalised, the 64-bit
# build called 64bit rather than amd64, and arm64 written ARM64. Guessing any of these
# produces a 404 at download time instead of a clear message here.
case "$(uname -m)" in
x86_64 | amd64) platform=Linux-64bit ;;
aarch64 | arm64) platform=Linux-ARM64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

version=${APP_VERSION:-}
if [ -z "$version" ]; then
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag,
	# so the newest release is asked of the project rather than guessed.
	echo "trivy install: no version was requested; taking the newest release" >&2
	latest=$(curl -fsSL https://api.github.com/repos/aquasecurity/trivy/releases/latest) ||
		fail "could not read the newest release from GitHub"
	version=$(printf '%s' "$latest" |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' |
		head -1)
	[ -n "$version" ] || fail "the release response names no version"
	echo "trivy install: newest release is $version" >&2
fi
version=${version#v}

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

root=${TRIVY_INSTALL_ROOT:-/opt/trivy}
bin_dir=${TRIVY_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"
link="$bin_dir/trivy"

work=$(mktemp -d)
tmp_link="$bin_dir/.trivy.orc.$$"
trap 'rm -rf "$work" "$tmp_link"' EXIT HUP INT TERM

# Repoints the exposure symlink atomically, so a concurrent `trivy` call never sees a
# missing PATH entry while versions are switched. terraform does the same.
expose() {
	mkdir -p "$bin_dir"
	[ ! -d "$link" ] || fail "$link is a directory"
	rm -f "$tmp_link"
	ln -s "$prefix/trivy" "$tmp_link"
	mv -f "$tmp_link" "$link"
}

# Already here? The pool image is baked straight after this phase and the node is then
# rebuilt from that image, which runs this phase again on a disk that already carries the
# binary. Without this check every node downloads the archive it is already holding.
if [ -x "$prefix/trivy" ] && reported=$("$prefix/trivy" --version 2>/dev/null); then
	case "$reported" in
	*"$version"*)
		expose
		echo "trivy install: trivy $version is already installed" >&2
		exit 0
		;;
	esac
fi

asset="trivy_${version}_${platform}.tar.gz"
sums="trivy_${version}_checksums.txt"
base="https://github.com/aquasecurity/trivy/releases/download/v$version"

echo "trivy install: downloading $asset" >&2
curl -fsSL "$base/$asset" -o "$work/$asset" || fail "could not download $asset"
curl -fsSL "$base/$sums" -o "$work/$sums" || fail "could not download $sums"

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

mkdir -p "$work/unpacked"
tar -xzf "$work/$asset" -C "$work/unpacked"

# Searched for rather than named: the archive also carries a licence and contrib files,
# and its layout is the project's to change.
binary=$(find "$work/unpacked" -type f -name trivy -perm -u+x | head -1)
[ -n "$binary" ] || fail "the trivy binary is missing from $asset"

# Claim only this version's own subtree: /opt/trivy may already hold other versions.
mkdir -p "$prefix"
install -m 0755 "$binary" "$prefix/trivy"

expose

reported=$("$prefix/trivy" --version) || fail "trivy does not run on this node"
case "$reported" in
*"$version"*) ;;
*) fail "installed version '$reported' does not match $version" ;;
esac

echo "trivy install: trivy $version installed at $prefix" >&2
