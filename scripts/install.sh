#!/bin/sh
# Download the public `orc` CLI from github.com/admte/orc into ./orc (repo root).
#
# Usage:
#   ./scripts/install.sh                    # latest stable release
#   ORC_VERSION=v0.5.2 ./scripts/install.sh # specific tag
set -eu

REPO="admte/orc"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEST="$ROOT_DIR/orc"

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
Darwin/arm64) asset="orc_darwin_arm64.tar.gz" ;;
Linux/x86_64 | Linux/amd64) asset="orc_linux_amd64.tar.gz" ;;
Linux/aarch64 | Linux/arm64) asset="orc_linux_arm64.tar.gz" ;;
*)
	echo "unsupported platform $os/$arch (supported: Darwin/arm64, Linux/amd64, Linux/arm64)" >&2
	echo "for Windows download orc_windows_amd64.zip from https://github.com/$REPO/releases" >&2
	exit 1
	;;
esac

version=${ORC_VERSION:-}
if [ -n "$version" ]; then
	base_url="https://github.com/$REPO/releases/download/$version"
else
	base_url="https://github.com/$REPO/releases/latest/download"
fi

if command -v sha256sum >/dev/null 2>&1; then
	checksum() { sha256sum "$1" | awk '{ print $1 }'; }
elif command -v shasum >/dev/null 2>&1; then
	checksum() { shasum -a 256 "$1" | awk '{ print $1 }'; }
else
	echo "need sha256sum or shasum to verify the release" >&2
	exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "Downloading $REPO ${version:-latest} ($asset)..." >&2
curl -fsSL "$base_url/$asset" -o "$tmp/$asset"
curl -fsSL "$base_url/SHA256SUMS" -o "$tmp/SHA256SUMS"

expected=$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1 }' "$tmp/SHA256SUMS")
if [ -z "$expected" ] || [ "$(checksum "$tmp/$asset")" != "$expected" ]; then
	echo "checksum verification failed for $asset" >&2
	exit 1
fi

tar -xzf "$tmp/$asset" -C "$tmp"
if [ ! -f "$tmp/orc" ]; then
	echo "no 'orc' binary in $asset" >&2
	exit 1
fi

mv "$tmp/orc" "$DEST"
chmod +x "$DEST"
echo "Installed orc -> $DEST" >&2
"$DEST" version
