#!/bin/sh
set -eu

fail() {
	echo "github-runner drain: $*" >&2
	exit 1
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

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[ -n "${URL:-}" ] || fail "URL is required"

work_dir=${WORK_DIR:-github-runner}
if [ ! -x "$work_dir/config.sh" ]; then
	echo "github-runner drain: $work_dir/config.sh not found; nothing to remove" >&2
	exit 0
fi

github_token=$(token_value)
api_path=$(github_api_path)
remove_json=$(curl -fsSL -X POST \
	-H "Accept: application/vnd.github+json" \
	-H "Authorization: token $github_token" \
	"https://api.github.com/$api_path/actions/runners/remove-token")
remove_token=$(printf '%s' "$remove_json" | json_field token)
[ -n "$remove_token" ] || fail "failed to create remove token"

(cd "$work_dir" && ./config.sh remove --token "$remove_token")
