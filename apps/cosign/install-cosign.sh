#!/bin/sh
set -eu

# Installs one cosign release into its own directory and exposes it through a symlink,
# the same shape trivy, syft, gitleaks and k6 use.
#
# One difference from all of them: sigstore publishes bare executables, not archives, so
# there is nothing to unpack — the download is the binary.

fail() {
	echo "cosign install: $*" >&2
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

case "$(uname -m)" in
x86_64 | amd64) platform=linux-amd64 ;;
aarch64 | arm64) platform=linux-arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

version=${APP_VERSION:-}
if [ -z "$version" ]; then
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag,
	# so the newest release is asked of the project rather than guessed.
	echo "cosign install: no version was requested; taking the newest release" >&2
	latest=$(curl -fsSL https://api.github.com/repos/sigstore/cosign/releases/latest) ||
		fail "could not read the newest release from GitHub"
	version=$(printf '%s' "$latest" |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' |
		head -1)
	[ -n "$version" ] || fail "the release response names no version"
	echo "cosign install: newest release is $version" >&2
fi
version=${version#v}

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

root=${COSIGN_INSTALL_ROOT:-/opt/cosign}
bin_dir=${COSIGN_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"
link="$bin_dir/cosign"

work=$(mktemp -d)
tmp_link="$bin_dir/.cosign.orc.$$"
trap 'rm -rf "$work" "$tmp_link"' EXIT HUP INT TERM

# Repoints the exposure symlink atomically, so a concurrent `cosign` call never sees a
# missing PATH entry while versions are switched.
expose() {
	mkdir -p "$bin_dir"
	[ ! -d "$link" ] || fail "$link is a directory"
	rm -f "$tmp_link"
	ln -s "$prefix/cosign" "$tmp_link"
	mv -f "$tmp_link" "$link"
}

# Both spellings are tried rather than betting on one.
reported_version() {
	"$1" version 2>/dev/null || "$1" --version 2>/dev/null || return 1
}

# Already here? The pool image is baked straight after this phase and the node is then
# rebuilt from that image, which runs this phase again on a disk that already carries the
# binary. Without this check every node downloads what it is already holding.
if [ -x "$prefix/cosign" ] && reported=$(reported_version "$prefix/cosign"); then
	case "$reported" in
	*"$version"*)
		expose
		echo "cosign install: cosign $version is already installed" >&2
		exit 0
		;;
	esac
fi

asset="cosign-$platform"
# The checksums file carries no version in its name, unlike every other package in this
# catalog — it is per release, found under the release's own download path.
sums="cosign_checksums.txt"
base="https://github.com/sigstore/cosign/releases/download/v$version"

echo "cosign install: downloading $asset" >&2
curl -fsSL "$base/$asset" -o "$work/$asset" || fail "could not download $asset"
curl -fsSL "$base/$sums" -o "$work/$sums" || fail "could not download $sums"

# Matched on the whole name: the release also publishes
# cosign-linux-amd64_<version>_linux_amd64.sbom.json and
# cosign-linux-pivkey-pkcs11key-amd64 beside it, and awk's field comparison is exact.
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

# Claim only this version's own subtree: /opt/cosign may already hold other versions.
mkdir -p "$prefix"
install -m 0755 "$work/$asset" "$prefix/cosign"

expose

reported=$(reported_version "$prefix/cosign") || fail "cosign does not run on this node"
case "$reported" in
*"$version"*) ;;
*) fail "installed version '$reported' does not match $version" ;;
esac

echo "cosign install: cosign $version installed at $prefix" >&2
