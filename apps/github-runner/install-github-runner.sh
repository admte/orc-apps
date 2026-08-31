#!/bin/sh
set -eu

SERVICE_USER=${SERVICE_USER:-ghrunner}

fail() {
	echo "github-runner install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# The Actions runner refuses to configure or run as root ("Must not run with
# sudo"), but lifecycle phases execute as root. Create a dedicated service
# account here so start-github-runner.sh can drop to it.
ensure_service_user() {
	if id "$SERVICE_USER" >/dev/null 2>&1; then
		return 0
	fi
	need useradd
	useradd -r -U -M -s /usr/sbin/nologin "$SERVICE_USER"
	id "$SERVICE_USER" >/dev/null 2>&1 || fail "failed to create service user $SERVICE_USER"
}

# Selects the runner build GitHub's service wants for this target from the
# runner-downloads API response: prints "download_url filename sha256_checksum".
select_download() {
	python3 -c '
import json, sys
target_os, target_arch = sys.argv[1], sys.argv[2]
for entry in json.load(sys.stdin):
    if entry.get("os") == target_os and entry.get("architecture") == target_arch:
        print(entry.get("download_url", ""))
        print(entry.get("filename", ""))
        print(entry.get("sha256_checksum", ""))
        break
' "$1" "$2"
}

token_value() {
	if [ -n "${TOKEN_FILE:-}" ]; then
		tr -d '\r\n' <"$TOKEN_FILE"
	elif [ -n "${TOKEN:-}" ]; then
		printf '%s' "$TOKEN"
	else
		fail "TOKEN_FILE or TOKEN is required"
	fi
}

github_api_path() {
	url=${URL:-}
	case "$url" in
	https://github.com/*) ;;
	*) fail "URL must start with https://github.com/" ;;
	esac
	path=${url#https://github.com/}
	path=${path%.git}
	path=${path%/}
	owner=${path%%/*}
	rest=${path#*/}
	[ -n "$owner" ] || fail "GitHub owner is required"
	if [ "$rest" != "$path" ] && [ -n "$rest" ]; then
		printf 'repos/%s/%s' "$owner" "$rest"
	else
		printf 'orgs/%s' "$owner"
	fi
}

runner_os() {
	case "$(uname -s)" in
	Linux) printf 'linux' ;;
	Darwin) printf 'osx' ;;
	*) fail "unsupported OS $(uname -s)" ;;
	esac
}

runner_arch() {
	case "$(uname -m)" in
	x86_64 | amd64) printf 'x64' ;;
	aarch64 | arm64) printf 'arm64' ;;
	*) fail "unsupported architecture $(uname -m)" ;;
	esac
}

need curl
need python3
# Not used here any more, but the start phase drops to the service account with
# it; a bake that produced an image without it would only fail at first boot.
need setpriv
need tar

[ -n "${URL:-}" ] || fail "URL is required"
github_token=$(token_value)
api_path=$(github_api_path)
work_dir=github-runner

[ "$(id -u)" -eq 0 ] || fail "must run as root"
ensure_service_user

mkdir -p "$work_dir"
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)

# Ask GitHub which runner build its service currently wants for this
# registration target (authenticated: 5000 req/h vs 60 unauthenticated).
# The runner self-updates afterward, so no version pinning here.
downloads_json=$(curl -fsSL \
	-H "Accept: application/vnd.github+json" \
	-H "Authorization: token $github_token" \
	"https://api.github.com/$api_path/actions/runners/downloads") ||
	fail "failed to list runner downloads"
selected=$(printf '%s' "$downloads_json" | select_download "$(runner_os)" "$(runner_arch)")
url=$(printf '%s\n' "$selected" | sed -n 1p)
archive=$(printf '%s\n' "$selected" | sed -n 2p)
checksum=$(printf '%s\n' "$selected" | sed -n 3p)
[ -n "$url" ] && [ -n "$archive" ] ||
	fail "no runner download for $(runner_os)/$(runner_arch)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "github-runner install: downloading the runner archive=$archive" >&2
curl -fsSL "$url" -o "$tmp/$archive"
if [ -n "$checksum" ]; then
	need sha256sum
	actual=$(sha256sum "$tmp/$archive" | awk '{ print $1 }')
	[ "$actual" = "$checksum" ] ||
		fail "checksum mismatch archive=$archive expected=$checksum actual=$actual"
	echo "github-runner install: checksum verified archive=$archive" >&2
else
	echo "github-runner install: no published checksum; skipping verification archive=$archive" >&2
fi
tar -xzf "$tmp/$archive" -C "$work_dir"
chown -R "$SERVICE_USER:$SERVICE_USER" "$work_dir"

# Nothing below this point may create node identity. A pool bake runs the install
# phase alone and snapshots the disk, so anything written here is shared by every
# clone of the image: registering would leave a dead runner on GitHub for a
# builder that no longer exists, and `config.sh` writes `.runner` and
# `.credentials` — the runner's own auth material — into the snapshot. The
# registration is start-github-runner.sh's, once per node.
echo "github-runner install: complete dir=$work_dir user=$SERVICE_USER" >&2
