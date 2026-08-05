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
# sudo"), but lifecycle phases execute as root. Register a dedicated service
# account and drop to it for every runner invocation.
ensure_service_user() {
	if id "$SERVICE_USER" >/dev/null 2>&1; then
		return 0
	fi
	need useradd
	useradd -r -U -M -s /usr/sbin/nologin "$SERVICE_USER"
	id "$SERVICE_USER" >/dev/null 2>&1 || fail "failed to create service user $SERVICE_USER"
}

# The service account is created without a home directory, so point HOME at the
# runner directory it owns; the runner writes dotfiles relative to HOME.
as_service_user() {
	su -s /bin/sh "$SERVICE_USER" -c "HOME=$(shell_quote "$work_dir"); export HOME; $1"
}

shell_quote() {
	printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/"
}

json_field() {
	python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
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
need tar
need python3

[ -n "${URL:-}" ] || fail "URL is required"
github_token=$(token_value)
api_path=$(github_api_path)
work_dir=${WORK_DIR:-github-runner}
runner_name=${RUNNER_NAME:-$(hostname)}
labels=${LABELS:-}

[ "$(id -u)" -eq 0 ] || fail "must run as root"
ensure_service_user

mkdir -p "$work_dir"
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)

latest_json=$(curl -fsSL -H "Accept: application/vnd.github+json" \
	"https://api.github.com/repos/actions/runner/releases/latest")
version=$(printf '%s' "$latest_json" | json_field tag_name)
version=${version#v}
[ -n "$version" ] || fail "failed to determine latest runner version"

archive="actions-runner-$(runner_os)-$(runner_arch)-$version.tar.gz"
url="https://github.com/actions/runner/releases/download/v$version/$archive"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading GitHub Actions runner $version ($archive)" >&2
curl -fsSL "$url" -o "$tmp/$archive"
tar -xzf "$tmp/$archive" -C "$work_dir"
chown -R "$SERVICE_USER:$SERVICE_USER" "$work_dir"

registration_json=$(curl -fsSL -X POST \
	-H "Accept: application/vnd.github+json" \
	-H "Authorization: token $github_token" \
	"https://api.github.com/$api_path/actions/runners/registration-token")
registration_token=$(printf '%s' "$registration_json" | json_field token)
[ -n "$registration_token" ] || fail "failed to create registration token"

set -- --name "$runner_name" --url "$URL" --token "$registration_token" --unattended --replace
if [ -n "$labels" ]; then
	set -- "$@" --labels "$labels"
fi

config_cmd="cd $(shell_quote "$work_dir") && ./config.sh"
for arg in "$@"; do
	config_cmd="$config_cmd $(shell_quote "$arg")"
done

echo "Configuring runner as $SERVICE_USER" >&2
as_service_user "$config_cmd"
