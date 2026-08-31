#!/bin/sh
set -eu

# Start phase: registration is node identity, so it happens here — once per node,
# every time a node that has none comes up — and never in install. A pool bake
# runs the install phase alone and snapshots the disk, so a registration made
# there would belong to a builder that is destroyed straight afterwards, and
# `config.sh` writes `.runner` and `.credentials` — the runner's own auth
# material — into an image every clone shares. Install leaves the runner
# unconfigured; this script gives the running node its own identity, then becomes
# the listener.

SERVICE_USER=${SERVICE_USER:-ghrunner}

fail() {
	echo "github-runner start: $*" >&2
	exit 1
}

note() {
	echo "github-runner start: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
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

github_get() {
	curl -fsSL \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: token $github_token" \
		"https://api.github.com/$1"
}

# Prints the numeric id of the runner registered under $1, or nothing.
runner_id_on_page() {
	python3 -c '
import json, sys
name = sys.argv[1]
for runner in json.load(sys.stdin).get("runners", []):
    if runner.get("name") == name:
        print(runner.get("id", ""))
        break
' "$1"
}

runner_page_count() {
	python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("runners", [])))'
}

# The API pages at 100; an org can register far more runners than that, so walk
# pages until one comes back short or the name is found. Same shape as
# stop-github-runner.sh, which looks the runner up to take the label off.
find_runner_id() {
	page=1
	while [ "$page" -le 20 ]; do
		body=$(github_get "$api_path/actions/runners?per_page=100&page=$page") || return 1
		id=$(printf '%s' "$body" | runner_id_on_page "$runner_name")
		if [ -n "$id" ]; then
			printf '%s' "$id"
			return 0
		fi
		[ "$(printf '%s' "$body" | runner_page_count)" -eq 100 ] || return 0
		page=$((page + 1))
	done
	return 0
}

# json.dumps, so a label with a quote or a backslash in it cannot break the body.
label_payload() {
	python3 -c 'import json,sys; print(json.dumps({"labels": [sys.argv[1]]}))' "$labels"
}

# Puts the pool label back. stop-github-runner.sh takes it off through the API so
# the queue stops routing work here during a drain, and the registration itself
# outlives every stop reason but `terminate` — so a drained node would otherwise
# come back online carrying only its default labels, and `runs-on: <pool>` would
# never match it again: healthy-looking, and silently never given another job.
# POST .../labels adds without replacing, so this is safe to run whether the
# config.sh above just passed --labels or the registration was already there.
#
# Every step fails explicitly, because the caller runs this in a subshell whose
# failure is only logged: a runner with no label still beats a node that will not
# start.
ensure_pool_label() {
	github_token=$(token_value)
	api_path=$(github_api_path)
	runner_id=$(find_runner_id) || fail "failed to list runners name=$runner_name"
	[ -n "$runner_id" ] || fail "runner is not registered name=$runner_name"
	curl -fsSL -X POST -o /dev/null \
		-H "Accept: application/vnd.github+json" \
		-H "Content-Type: application/json" \
		-H "Authorization: token $github_token" \
		-d "$(label_payload)" \
		"https://api.github.com/$api_path/actions/runners/$runner_id/labels" ||
		fail "label request failed name=$runner_name id=$runner_id label=$labels"
	note "pool label ensured name=$runner_name id=$runner_id label=$labels"
}

# setpriv, never su or runuser: those start a new session, which is what puts an
# app outside the process group the runtime signals. The account has no home
# directory, so HOME points at the runner directory it owns.
as_service_user() {
	setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
		env HOME="$work_dir" "$@"
}

need curl
need hostname
need python3
need setpriv

work_dir=github-runner
[ -x "$work_dir/config.sh" ] ||
	fail "no runner install found; install must run first dir=$work_dir"
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)
cd "$work_dir"

# The runner name is the host name (a pool member is `<pool>-<slot>`). Its label
# is the pool name, sourced from the `pool.name` x-source (env POOL).
runner_name=$(hostname)
labels=${POOL:-}

# `.runner` is the file config.sh writes when a directory has been configured; it
# and the `.credentials` beside it are this node's identity. Absent means the node
# has none yet — a fresh install, or the first boot of a clone whose baked image
# carried the unpacked runner but deliberately no identity — so register. Present
# means an ordinary service restart, and config.sh refuses an already-configured
# directory, so registration is skipped and the same identity is reused. The
# stopped hook's `config.sh remove` deletes `.runner`, which is what makes a
# terminated-then-restarted install register again rather than start unconfigured.
if [ -f .runner ]; then
	note "already registered; reusing this node's identity name=$runner_name dir=$work_dir"
else
	[ -n "${URL:-}" ] || fail "URL is required"
	github_token=$(token_value)
	api_path=$(github_api_path)

	# A registration token is short-lived, so it is minted at the moment it is
	# used and never persisted.
	registration_json=$(curl -fsSL -X POST \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: token $github_token" \
		"https://api.github.com/$api_path/actions/runners/registration-token") ||
		fail "failed to create registration token"
	registration_token=$(printf '%s' "$registration_json" | json_field token)
	[ -n "$registration_token" ] || fail "failed to create registration token"

	set -- --name "$runner_name" --url "$URL" --token "$registration_token" --unattended --replace
	if [ -n "$labels" ]; then
		set -- "$@" --labels "$labels"
	fi

	note "registering name=$runner_name labels=$labels user=$SERVICE_USER"
	as_service_user ./config.sh "$@"
fi

# Runs on both paths, and never fatally: the subshell contains a hard failure
# from anything inside, so the listener starts either way.
if [ -z "$labels" ]; then
	note "no pool label to ensure name=$runner_name"
else
	(ensure_pool_label) ||
		note "could not ensure the pool label; starting without it name=$runner_name label=$labels"
fi

note "starting the listener name=$runner_name dir=$work_dir"
exec setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
	env HOME="$work_dir" ./run.sh
