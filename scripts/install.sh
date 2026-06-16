#!/bin/sh
# Download the `orc` CLI from github.com/admte/orc-cli releases into ./orc (repo root).
#
# orc-cli is a PRIVATE repo, so a GitHub token with `repo` scope is required:
#   export GITHUB_TOKEN=$(gh auth token)     # or a PAT
#
# Usage:
#   ./scripts/install.sh                      # latest release
#   ORC_VERSION=v0.3.0 ./scripts/install.sh   # specific tag
set -eu

REPO="admte/orc-cli"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEST="$ROOT_DIR/orc"

# --- detect platform -> release asset ----------------------------------------
os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
Darwin/arm64) asset="orc-darwin-arm64.tar.gz" ;;
Linux/x86_64 | Linux/amd64) asset="orc-linux-amd64.tar.gz" ;;
*)
	echo "unsupported platform $os/$arch (supported: Darwin/arm64, Linux/x86_64)" >&2
	echo "for Windows download orc-windows-amd64.zip from https://github.com/$REPO/releases" >&2
	exit 1
	;;
esac

# --- token (required: private repo) ------------------------------------------
token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$token" ]; then
	echo "GITHUB_TOKEN (or GH_TOKEN) is required to download from the private repo $REPO" >&2
	echo "  export GITHUB_TOKEN=\$(gh auth token)" >&2
	exit 1
fi

api_get() { curl -fsSL -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" "$1"; }

# JSON parsing via jq (preferred) or python3 — both common on dev machines and CI runners.
if command -v jq >/dev/null 2>&1; then
	json_field() { jq -r "$1"; }                                   # $1 = jq filter, stdin = JSON
elif command -v python3 >/dev/null 2>&1; then
	json_tag()  { python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))'; }
	json_asset() { python3 -c 'import sys,json;n=sys.argv[1];print(next((a["id"] for a in json.load(sys.stdin).get("assets",[]) if a["name"]==n),""))' "$1"; }
else
	echo "need jq or python3 to parse the GitHub API response" >&2
	exit 1
fi

# --- resolve release ---------------------------------------------------------
version="${ORC_VERSION:-}"
if [ -n "$version" ]; then
	rel_url="https://api.github.com/repos/$REPO/releases/tags/$version"
else
	rel_url="https://api.github.com/repos/$REPO/releases/latest"
fi
release_json=$(api_get "$rel_url")
if command -v jq >/dev/null 2>&1; then
	version=$(printf '%s' "$release_json" | json_field '.tag_name')
	asset_id=$(printf '%s' "$release_json" | json_field ".assets[]|select(.name==\"$asset\").id")
else
	version=$(printf '%s' "$release_json" | json_tag)
	asset_id=$(printf '%s' "$release_json" | json_asset "$asset")
fi
[ -n "$asset_id" ] || { echo "asset $asset not found in release $version" >&2; exit 1; }

echo "Downloading $REPO $version ($asset)..." >&2

# --- download (API asset endpoint works for private repos) -------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -H "Authorization: Bearer $token" -H "Accept: application/octet-stream" \
	"https://api.github.com/repos/$REPO/releases/assets/$asset_id" -o "$tmp/$asset"
tar -xzf "$tmp/$asset" -C "$tmp"

bin=$(find "$tmp" -type f -name orc | head -n1)
[ -n "$bin" ] || { echo "no 'orc' binary in $asset" >&2; exit 1; }

mv "$bin" "$DEST"
chmod +x "$DEST"

echo "Installed orc -> $DEST" >&2
"$DEST" version
