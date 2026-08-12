#!/bin/sh
set -eu

fail() {
	echo "codex install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

if command -v codex >/dev/null 2>&1 &&
	[ -z "${APP_VERSION:-}" ] &&
	[ -z "${CODEX_FORCE_INSTALL:-}" ]; then
	codex --version
	exit 0
fi

case "$(uname -s)" in
Linux) platform=unknown-linux-musl ;;
Darwin) platform=apple-darwin ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch=x86_64 ;;
aarch64 | arm64) arch=aarch64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

need curl
need tar
archive="codex-package-$arch-$platform.tar.gz"
if [ -n "${APP_VERSION:-}" ]; then
	version=${APP_VERSION#rust-v}
	version=${version#v}
	base_url="https://github.com/openai/codex/releases/download/rust-v$version"
else
	base_url="https://github.com/openai/codex/releases/latest/download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
echo "Downloading Codex CLI for $arch-$platform" >&2
curl -fsSL "$base_url/$archive" -o "$tmp/$archive"
curl -fsSL "$base_url/codex-package_SHA256SUMS" -o "$tmp/SHA256SUMS"

expected=$(awk -v archive="$archive" '$2 == archive { print $1 }' "$tmp/SHA256SUMS")
[ -n "$expected" ] || fail "checksum for $archive was not published"
if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$tmp/$archive" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
	actual=$(shasum -a 256 "$tmp/$archive" | awk '{ print $1 }')
else
	fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "checksum verification failed for $archive"

tar -xzf "$tmp/$archive" -C "$tmp"
[ -x "$tmp/bin/codex" ] || fail "Codex CLI binary is missing from $archive"

install_dir=${CODEX_INSTALL_DIR:-/usr/local/bin}
package_dir="$install_dir/.codex-package"
mkdir -p "$install_dir"
rm -rf "$package_dir"
mkdir -p "$package_dir"
(cd "$tmp" && tar -cf - bin codex-package.json codex-path codex-resources) |
	(cd "$package_dir" && tar -xf -)
ln -sf ".codex-package/bin/codex" "$install_dir/codex"
"$install_dir/codex" --version
