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

# The token param holds either an operator's personal access token or a
# registration orc8r minted for this node, a JSON object. They are told apart by
# shape: a value whose first non-blank character is `{` is the minted credential.
is_minted() {
	trimmed=${1#"${1%%[![:space:]]*}"}
	case "$trimmed" in
	'{'*) return 0 ;;
	*) return 1 ;;
	esac
}

# Reads a minted credential from stdin and prints its url, token, name and labels
# (joined by commas), one per line. Two modes are understood: `persistent`, a
# repository runner, and `persistent-org`, an organization runner whose url is
# `https://<host>[:port]/<org>`, on github.com or an Enterprise Server. Any other
# mode stops here with the message orc8r and an operator look for, so a credential
# meant for a scope this version does not know is never registered as something
# else. Labels are required: the runner
# registers with them alone, without GitHub's default labels.
minted_registration() {
	python3 -c '
import json, re, sys
def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)
try:
    cred = json.load(sys.stdin)
except ValueError as err:
    die("github-runner start: the minted credential is not valid JSON: %s" % err)
if not isinstance(cred, dict):
    die("github-runner start: the minted credential is not a JSON object")
mode = cred.get("mode")
if mode not in ("persistent", "persistent-org"):
    die("github-runner: credential mode %s is not supported by this version" % mode)
fields = []
for key in ("url", "token", "name"):
    value = cred.get(key)
    if not isinstance(value, str) or not value:
        die("github-runner start: the minted credential has no %s" % key)
    fields.append(value)
# https, a host with an optional port, then exactly one path segment (the org) and
# at most one trailing slash; no query or fragment. Kept as one pattern so the ps1
# check is the same expression.
org_url = r"https://[A-Za-z0-9.-]+(:[0-9]+)?/[^/?#]+/?"
if mode == "persistent-org" and not re.fullmatch(org_url, fields[0]):
    die("github-runner start: a persistent-org credential url must be https://<host>/<org>")
labels = cred.get("labels") or []
if not isinstance(labels, list) or not all(isinstance(l, str) and l for l in labels):
    die("github-runner start: the minted credential labels must be a list of names")
if not labels:
    die("github-runner start: the minted credential has no labels")
if any("," in l for l in labels):
    die("github-runner start: a minted credential label contains a comma")
fields.append(",".join(labels))
if any("\n" in f or "\r" in f for f in fields):
    die("github-runner start: a minted credential field contains a line break")
print("\n".join(fields))
'
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
# Prints the name a configured directory registered under, from the agentName in
# `.runner` (which config.sh writes with a UTF-8 BOM), or nothing if unreadable.
registered_name() {
	python3 -c '
import json
try:
    with open(".runner", encoding="utf-8-sig") as f:
        print(json.load(f).get("agentName") or "")
except Exception:
    pass
' 2>/dev/null || true
}

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
# directory, so registration is skipped and the same identity is reused. With a
# personal access token, the stopped hook's `config.sh remove` deletes `.runner`,
# which is what makes a terminated-then-restarted install register again rather
# than start unconfigured.
#
# A registration orc8r minted carries its own url — a repository or, in the
# persistent-org mode, an organization — runner name and labels, and the token in
# it is already a registration token, so it goes to config.sh as is; the
# operator's URL, the host name and POOL are not used for it. An absent token
# is not fatal here: a node with `.runner` starts without one, and the PAT
# registration below fails on it by name.
credential=$(token_value 2>/dev/null) || credential=
if is_minted "$credential"; then
	minted=yes
else
	minted=no
fi

if [ -f .runner ]; then
	registered=$(registered_name)
	runner_name=${registered:-$runner_name}
	note "already registered; reusing this node's identity name=$runner_name dir=$work_dir"
elif [ "$minted" = yes ]; then
	registration=$(printf '%s' "$credential" | minted_registration) || exit 1
	minted_url=$(printf '%s\n' "$registration" | sed -n 1p)
	minted_token=$(printf '%s\n' "$registration" | sed -n 2p)
	runner_name=$(printf '%s\n' "$registration" | sed -n 3p)
	labels=$(printf '%s\n' "$registration" | sed -n 4p)

	# Only the credential's labels, none of GitHub's defaults: a job elsewhere in
	# the repository or organization that asks for `self-hosted`, an OS or an
	# architecture must not land on a machine orc8r runs for one pool.
	set -- --unattended --url "$minted_url" --token "$minted_token" --name "$runner_name" \
		--no-default-labels --labels "$labels" --replace

	note "registering with the minted registration name=$runner_name labels=$labels user=$SERVICE_USER"
	as_service_user ./config.sh "$@"
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

# Runs on both PAT paths, and never fatally: the subshell contains a hard failure
# from anything inside, so the listener starts either way. A minted registration
# set its labels at registration and holds no API credential, so there is nothing
# to restore: stop leaves them alone too.
if [ "$minted" = yes ]; then
	note "labels were set at registration; no label upkeep name=$runner_name"
elif [ -z "$labels" ]; then
	note "no pool label to ensure name=$runner_name"
else
	(ensure_pool_label) ||
		note "could not ensure the pool label; starting without it name=$runner_name label=$labels"
fi

note "starting the listener name=$runner_name dir=$work_dir"
exec setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
	env HOME="$work_dir" ./run.sh
