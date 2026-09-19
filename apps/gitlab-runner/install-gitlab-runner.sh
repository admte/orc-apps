#!/bin/sh
set -eu

SERVICE_USER=${SERVICE_USER:-gitlab-runner}
DOWNLOADS=${GITLAB_RUNNER_DOWNLOADS:-https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads}

fail() {
	echo "gitlab-runner install: $*" >&2
	exit 1
}

note() {
	echo "gitlab-runner install: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# The runner process itself stays root so the platform can signal it; jobs run as
# this account, which is what `gitlab-runner run --user` selects. GitLab's own
# manual install creates the same account, with a home directory and a real shell
# because the shell executor runs job scripts as this user.
ensure_service_user() {
	if id "$SERVICE_USER" >/dev/null 2>&1; then
		return 0
	fi
	need useradd
	useradd --comment 'GitLab Runner' --create-home --shell /bin/bash "$SERVICE_USER"
	id "$SERVICE_USER" >/dev/null 2>&1 || fail "failed to create service user $SERVICE_USER"
}

# Every release publishes an index listing each file with its SHA-256; this pulls
# out the one belonging to $1. The link text is matched up to its closing tag so
# gitlab-runner-linux-amd64 cannot match gitlab-runner-linux-amd64-fips.
asset_checksum() {
	python3 -c '
import re, sys
asset = sys.argv[1]
page = sys.stdin.read()
pattern = (
    r"binaries/" + re.escape(asset) + r"</a></span>\s*"
    r"<span class=\"file_checksum\">([0-9a-f]{64})</span>"
)
found = re.search(pattern, page)
print(found.group(1) if found else "")
' "$1"
}

need curl
need python3
need sha256sum
[ "$(id -u)" -eq 0 ] || fail "must run as root"

[ -n "${APP_VERSION:-}" ] || fail "APP_VERSION is required"
case "$APP_VERSION" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid APP_VERSION: $APP_VERSION" ;;
esac

case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

asset="gitlab-runner-linux-$arch"
base="$DOWNLOADS/v$APP_VERSION"
root=${GITLAB_RUNNER_INSTALL_ROOT:-/opt/gitlab-runner}
bin_dir=${GITLAB_RUNNER_BIN_DIR:-/usr/local/bin}
prefix="$root/$APP_VERSION"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

ensure_service_user

note "downloading the runner version=$APP_VERSION asset=$asset"
curl -fsSL "$base/binaries/$asset" -o "$work/$asset" ||
	fail "no GitLab Runner $APP_VERSION build for linux/$arch"
expected=$(curl -fsSL "$base/index.html" | asset_checksum "$asset")
[ -n "$expected" ] || fail "no published checksum for $asset in release v$APP_VERSION"
actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] ||
	fail "checksum verification failed asset=$asset expected=$expected actual=$actual"

install -D -m 0755 "$work/$asset" "$prefix/gitlab-runner"
mkdir -p "$bin_dir"
ln -sfn "$prefix/gitlab-runner" "$bin_dir/gitlab-runner"
ln -sfn "$prefix" "$root/current"

version_output=$("$prefix/gitlab-runner" --version)
case "$version_output" in
*"Version:"*"$APP_VERSION"*) note "installed version=$APP_VERSION dir=$prefix user=$SERVICE_USER" ;;
*) fail "installed runner does not report $APP_VERSION: $version_output" ;;
esac

# Nothing below this point may create node identity. A pool bake runs the install
# phase alone and snapshots the disk, so a `register` here would put one runner
# manager's entry into config.toml for every clone of the image. Registration is
# start-gitlab-runner.sh's, once per node.
