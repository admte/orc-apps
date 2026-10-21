#!/bin/sh
set -eu

# Installs one mise release into its own directory and exposes it through a symlink,
# the same shape cosign, trivy, syft, gitleaks, k6 and snyk use.
#
# Like cosign and snyk, the project publishes bare executables alongside its archives, so
# the plain binary is taken and there is nothing to unpack.

fail() {
	echo "mise install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

need curl
need mktemp

case "$(uname -s)" in
Linux) ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac

# The project also builds musl variants; these nodes are glibc, so the plain ones are
# the right assets here.
case "$(uname -m)" in
x86_64 | amd64) platform=linux-x64 ;;
aarch64 | arm64) platform=linux-arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

version=${APP_VERSION:-}
if [ -z "$version" ]; then
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag,
	# so the newest release is asked of the project rather than guessed.
	echo "mise install: no version was requested; taking the newest release" >&2
	latest=$(curl -fsSL https://api.github.com/repos/jdx/mise/releases/latest) ||
		fail "could not read the newest release from GitHub"
	version=$(printf '%s' "$latest" |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' |
		head -1)
	[ -n "$version" ] || fail "the release response names no version"
	echo "mise install: newest release is $version" >&2
fi
version=${version#v}

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

root=${MISE_INSTALL_ROOT:-/opt/mise}
bin_dir=${MISE_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"
link="$bin_dir/mise"

work=$(mktemp -d)
tmp_link="$bin_dir/.mise.orc.$$"
trap 'rm -rf "$work" "$tmp_link"' EXIT HUP INT TERM

# Repoints the exposure symlink atomically, so a concurrent `mise` call never sees a
# missing PATH entry while versions are switched.
expose() {
	mkdir -p "$bin_dir"
	[ ! -d "$link" ] || fail "$link is a directory"
	rm -f "$tmp_link"
	ln -s "$prefix/mise" "$tmp_link"
	mv -f "$tmp_link" "$link"
}

# Both spellings are tried rather than betting on one.
reported_version() {
	"$1" --version 2>/dev/null || "$1" version 2>/dev/null || return 1
}

# Already here? The pool image is baked straight after this phase and the node is then
# rebuilt from that image, which runs this phase again on a disk that already carries the
# binary. Without this check every node downloads what it is already holding.
if [ -x "$prefix/mise" ] && reported=$(reported_version "$prefix/mise"); then
	case "$reported" in
	*"$version"*)
		expose
		echo "mise install: mise $version is already installed" >&2
		exit 0
		;;
	esac
fi

# The version is part of the asset name, as with k6.
asset="mise-v$version-$platform"
sums="SHASUMS256.txt"
base="https://github.com/jdx/mise/releases/download/v$version"

echo "mise install: downloading $asset" >&2
curl -fsSL "$base/$asset" -o "$work/$asset" || fail "could not download $asset"
curl -fsSL "$base/$sums" -o "$work/$sums" || fail "could not download $sums"

# Matched on the whole name: mise-v<ver>-linux-x64 is a prefix of its -musl sibling and
# of every archive of the same build. The names in this file carry a "./" prefix, which
# the second comparison allows for without loosening the match.
expected=$(awk -v asset="$asset" '$2 == asset || $2 == "./" asset { print $1 }' "$work/$sums")
[ -n "$expected" ] || fail "checksum for $asset was not published"

if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
	actual=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
else
	fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

# Claim only this version's own subtree: /opt/mise may already hold other versions.
mkdir -p "$prefix"
install -m 0755 "$work/$asset" "$prefix/mise"

expose

reported=$(reported_version "$prefix/mise") || fail "mise does not run on this node"
case "$reported" in
*"$version"*) ;;
*) fail "installed version '$reported' does not match $version" ;;
esac

echo "mise install: mise $version installed at $prefix" >&2
