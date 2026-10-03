#!/bin/sh
set -eu

# Installs one k6 release into its own directory and exposes it through a symlink,
# the same shape go, java, node, terraform, trivy and syft use.

fail() {
	echo "k6 install: $*" >&2
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

# The project's own naming, taken from its checksums file: hyphens, and the version
# written with its leading "v" inside the file name — unlike trivy, gitleaks and syft,
# where the archives carry the bare number. Copied from the file, not guessed.
case "$(uname -m)" in
x86_64 | amd64) platform=linux-amd64 ;;
aarch64 | arm64) platform=linux-arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

version=${APP_VERSION:-}
if [ -z "$version" ]; then
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag,
	# so the newest release is asked of the project rather than guessed.
	echo "k6 install: no version was requested; taking the newest release" >&2
	latest=$(curl -fsSL https://api.github.com/repos/grafana/k6/releases/latest) ||
		fail "could not read the newest release from GitHub"
	version=$(printf '%s' "$latest" |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' |
		head -1)
	[ -n "$version" ] || fail "the release response names no version"
	echo "k6 install: newest release is $version" >&2
fi
version=${version#v}

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

root=${K6_INSTALL_ROOT:-/opt/k6}
bin_dir=${K6_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"
link="$bin_dir/k6"

work=$(mktemp -d)
tmp_link="$bin_dir/.k6.orc.$$"
trap 'rm -rf "$work" "$tmp_link"' EXIT HUP INT TERM

# Repoints the exposure symlink atomically, so a concurrent `k6` call never sees a
# missing PATH entry while versions are switched.
expose() {
	mkdir -p "$bin_dir"
	[ ! -d "$link" ] || fail "$link is a directory"
	rm -f "$tmp_link"
	ln -s "$prefix/k6" "$tmp_link"
	mv -f "$tmp_link" "$link"
}

# Both spellings are tried rather than betting on one.
reported_version() {
	"$1" version 2>/dev/null || "$1" --version 2>/dev/null || return 1
}

# Already here? The pool image is baked straight after this phase and the node is then
# rebuilt from that image, which runs this phase again on a disk that already carries the
# binary. Without this check every node downloads the archive it is already holding.
if [ -x "$prefix/k6" ] && reported=$(reported_version "$prefix/k6"); then
	case "$reported" in
	*"$version"*)
		expose
		echo "k6 install: k6 $version is already installed" >&2
		exit 0
		;;
	esac
fi

asset="k6-v${version}-${platform}.tar.gz"
sums="k6-v${version}-checksums.txt"
base="https://github.com/grafana/k6/releases/download/v$version"

echo "k6 install: downloading $asset" >&2
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

# Searched for rather than named: this archive puts the binary inside a directory named
# after the build, and that layout is the project's to change.
binary=$(find "$work/unpacked" -type f -name k6 -perm -u+x | head -1)
[ -n "$binary" ] || fail "the k6 binary is missing from $asset"

# Claim only this version's own subtree: /opt/k6 may already hold other versions.
mkdir -p "$prefix"
install -m 0755 "$binary" "$prefix/k6"

expose

reported=$(reported_version "$prefix/k6") || fail "k6 does not run on this node"
case "$reported" in
*"$version"*) ;;
*) fail "installed version '$reported' does not match $version" ;;
esac

echo "k6 install: k6 $version installed at $prefix" >&2
