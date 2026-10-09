#!/bin/sh
set -eu

# Installs one Snyk CLI release into its own directory and exposes it through a symlink,
# the same shape cosign, trivy, syft, gitleaks and k6 use.
#
# Like cosign, snyk publishes bare executables rather than archives, so there is nothing
# to unpack. Unlike cosign, there is no single checksums file: each binary carries its
# own <asset>.sha256 beside it.

fail() {
	echo "snyk install: $*" >&2
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

# snyk-alpine is the musl build; these nodes are glibc, so only the two linux assets
# below are ever correct here.
case "$(uname -m)" in
x86_64 | amd64) asset=snyk-linux ;;
aarch64 | arm64) asset=snyk-linux-arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

version=${APP_VERSION:-}
if [ -z "$version" ]; then
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag,
	# so the newest release is asked of the project rather than guessed.
	echo "snyk install: no version was requested; taking the newest release" >&2
	latest=$(curl -fsSL https://api.github.com/repos/snyk/cli/releases/latest) ||
		fail "could not read the newest release from GitHub"
	version=$(printf '%s' "$latest" |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' |
		head -1)
	[ -n "$version" ] || fail "the release response names no version"
	echo "snyk install: newest release is $version" >&2
fi
version=${version#v}

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

root=${SNYK_INSTALL_ROOT:-/opt/snyk}
bin_dir=${SNYK_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"
link="$bin_dir/snyk"

work=$(mktemp -d)
tmp_link="$bin_dir/.snyk.orc.$$"
trap 'rm -rf "$work" "$tmp_link"' EXIT HUP INT TERM

# Repoints the exposure symlink atomically, so a concurrent `snyk` call never sees a
# missing PATH entry while versions are switched.
expose() {
	mkdir -p "$bin_dir"
	[ ! -d "$link" ] || fail "$link is a directory"
	rm -f "$tmp_link"
	ln -s "$prefix/snyk" "$tmp_link"
	mv -f "$tmp_link" "$link"
}

# Both spellings are tried rather than betting on one.
reported_version() {
	"$1" --version 2>/dev/null || "$1" version 2>/dev/null || return 1
}

# Already here? The pool image is baked straight after this phase and the node is then
# rebuilt from that image, which runs this phase again on a disk that already carries the
# binary. Without this check every node downloads what it is already holding.
if [ -x "$prefix/snyk" ] && reported=$(reported_version "$prefix/snyk"); then
	case "$reported" in
	*"$version"*)
		expose
		echo "snyk install: snyk $version is already installed" >&2
		exit 0
		;;
	esac
fi

# Each asset has its own checksum file; there is no combined one. The release does carry
# sha256sums.txt.asc, but that is PGP-signed text and verifying it would need the
# project's key on the node.
sums="$asset.sha256"
base="https://github.com/snyk/cli/releases/download/v$version"

echo "snyk install: downloading $asset" >&2
curl -fsSL "$base/$asset" -o "$work/$asset" || fail "could not download $asset"
curl -fsSL "$base/$sums" -o "$work/$sums" || fail "could not download $sums"

# Matched on the whole name with awk's exact field comparison: snyk-linux and
# snyk-linux-arm64 share a prefix, and so do their checksum files.
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

# Claim only this version's own subtree: /opt/snyk may already hold other versions.
mkdir -p "$prefix"
install -m 0755 "$work/$asset" "$prefix/snyk"

expose

reported=$(reported_version "$prefix/snyk") || fail "snyk does not run on this node"
case "$reported" in
*"$version"*) ;;
*) fail "installed version '$reported' does not match $version" ;;
esac

echo "snyk install: snyk $version installed at $prefix" >&2
