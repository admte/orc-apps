#!/bin/sh
set -eu

SERVICE_USER=${SERVICE_USER:-azagent}
RELEASES=${AZP_RELEASES_API:-https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/latest}
DOWNLOADS=${AZP_DOWNLOADS:-https://download.agent.dev.azure.com/agent}

fail() {
	echo "azure-pipelines-agent install: $*" >&2
	exit 1
}

note() {
	echo "azure-pipelines-agent install: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# The agent refuses to run as a service under root, but lifecycle phases execute
# as root. Create a dedicated service account here so start-azure-pipelines-agent
# can drop to it.
ensure_service_user() {
	if id "$SERVICE_USER" >/dev/null 2>&1; then
		return 0
	fi
	need useradd
	useradd -r -U -m -d "/home/$SERVICE_USER" -s /bin/bash "$SERVICE_USER"
	id "$SERVICE_USER" >/dev/null 2>&1 || fail "failed to create service user $SERVICE_USER"
}

# The release the project currently publishes, as "<version>". The agent updates
# itself afterwards, so this is a starting point rather than a pin.
release_version() {
	python3 -c '
import json, sys
tag = json.load(sys.stdin).get("tag_name", "")
print(tag[1:] if tag.startswith("v") else tag)
'
}

# Each release body carries a table of every package with its SHA-256. The row is
# matched on the full file name, which no other row contains as a substring.
release_checksum() {
	python3 -c '
import json, re, sys
asset = sys.argv[1]
body = json.load(open(sys.argv[2])).get("body", "")
for line in body.splitlines():
    if asset in line:
        for cell in line.split("|"):
            cell = cell.strip()
            if re.fullmatch(r"[0-9a-f]{64}", cell):
                print(cell)
                sys.exit(0)
print("")
' "$1" "$2"
}

need curl
need id
need python3
need sha256sum
need tar
# Not used here, but the start phase drops to the service account with setpriv and
# the stop phase looks the worker up with pgrep; a bake that produced an image
# without them would only fail at first boot.
need setpriv
need hostname
need pgrep
[ "$(id -u)" -eq 0 ] || fail "must run as root"

case "$(uname -m)" in
x86_64 | amd64) arch=x64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

work_dir=azure-pipelines-agent
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; exit 1' HUP INT TERM

ensure_service_user

curl -fsSL -H 'Accept: application/vnd.github+json' "$RELEASES" -o "$work/release.json" ||
	fail "could not read the agent release index"
version=$(release_version <"$work/release.json")
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "unexpected agent version: ${version:-<empty>}" ;;
esac

asset="vsts-agent-linux-$arch-$version.tar.gz"
expected=$(release_checksum "$asset" "$work/release.json")
[ -n "$expected" ] || fail "no published checksum for $asset in release v$version"

note "downloading the agent version=$version asset=$asset"
curl -fsSL "$DOWNLOADS/$version/$asset" -o "$work/$asset" ||
	fail "no agent build for linux/$arch in release v$version"
actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] ||
	fail "checksum verification failed asset=$asset expected=$expected actual=$actual"

mkdir -p "$work_dir"
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)
tar -xzf "$work/$asset" -C "$work_dir"
[ -x "$work_dir/config.sh" ] || fail "config.sh is missing from $asset"
chown -R "$SERVICE_USER" "$work_dir"

note "installed version=$version dir=$work_dir user=$SERVICE_USER"

# Nothing below this point may create node identity. A pool bake runs the install
# phase alone and snapshots the disk, so anything written here is shared by every
# clone of the image: registering would leave a dead agent in the pool for a
# builder that no longer exists, and `config.sh` writes `.agent` and
# `.credentials` — the agent's own auth material — into the snapshot. The
# registration is start-azure-pipelines-agent.sh's, once per node.
