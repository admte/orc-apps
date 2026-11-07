#!/bin/sh
set -eu

# Registration gives a machine its own runner identity, so it happens here — the
# first time the runner starts on a machine that has none — and never in install:
# an installed disk may be imaged and copied, and `config.sh` writes `.runner`
# and `.credentials` — the runner's own auth material — that every copy would
# share. Install leaves the runner unconfigured; this script registers it, then
# becomes the listener.

usage() {
	cat <<'USAGE'
Usage: start-github-runner.sh [--url=URL] [--token-file=PATH] [--labels=LIST]
                              [--service-user=NAME]

Registers this machine's runner if it has no identity yet, then becomes the
listener. Run as root from the directory install ran in.

  --url=URL            repository or organization URL; used with a personal
                       access token, ignored for a JSON registration
  --token-file=PATH    file holding a personal access token or a runner
                       registration as a JSON object; optional when already
                       registered
  --labels=LIST        comma-separated labels the runner carries with a personal
                       access token
  --service-user=NAME  account the listener runs as (default: ghrunner)
  --help               show this help
USAGE
}

fail() {
	echo "github-runner start: $*" >&2
	exit 1
}

usage_error() {
	echo "github-runner start: $*" >&2
	usage >&2
	exit 2
}

# Sets labels to the comma-separated list in $1 with the space around each item
# trimmed and empty items dropped. GitHub refuses a label with a space in it or
# longer than 256 characters, so such a label stops here.
parse_labels() {
	labels=
	rest=$1,
	while [ -n "$rest" ]; do
		item=${rest%%,*}
		rest=${rest#*,}
		item=${item#"${item%%[![:space:]]*}"}
		item=${item%"${item##*[![:space:]]}"}
		[ -n "$item" ] || continue
		case $item in
		*[[:space:][:cntrl:]]*) usage_error "label '$item' contains a space or a control character" ;;
		esac
		[ "${#item}" -le 256 ] || usage_error "label '$item' is longer than 256 characters"
		labels=${labels:+$labels,}$item
	done
}

repo_url=
token_file=
labels_arg=
service_user=ghrunner
for arg; do
	case $arg in
	--url=*) repo_url=${arg#--url=} ;;
	--token-file=*) token_file=${arg#--token-file=} ;;
	--labels=*) labels_arg=${arg#--labels=} ;;
	--service-user=*) service_user=${arg#--service-user=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$service_user" ] || usage_error "--service-user must not be empty"
parse_labels "$labels_arg"

# Progress goes to stdout and only warnings and errors to stderr, so a healthy
# start writes nothing there.
note() {
	echo "github-runner start: $*"
}

warn() {
	echo "github-runner start: warning: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

json_field() {
	python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

token_value() {
	[ -n "$token_file" ] || fail "--token-file is required"
	tr -d '\r\n' <"$token_file"
}

# The token file holds either a personal access token or a runner registration
# supplied as a JSON object. They are told apart by shape: a value whose first
# non-blank character is `{` is the JSON registration.
is_minted() {
	trimmed=${1#"${1%%[![:space:]]*}"}
	case "$trimmed" in
	'{'*) return 0 ;;
	*) return 1 ;;
	esac
}

# Reads a JSON registration from stdin and prints its url, token, name and labels
# (joined by commas), one per line. Two modes are understood: `persistent`, a
# repository runner, and `persistent-org`, an organization runner whose url is
# `https://<host>[:port]/<org>`, on github.com or an Enterprise Server. Any other
# mode stops here with a fixed message, so a registration meant for a scope this
# version does not know is never registered as something else. Labels are
# required: the runner registers with them alone, without GitHub's default labels.
minted_registration() {
	python3 -c '
import json, re, sys
def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)
try:
    cred = json.load(sys.stdin)
except ValueError as err:
    die("github-runner start: the registration is not valid JSON: %s" % err)
if not isinstance(cred, dict):
    die("github-runner start: the registration is not a JSON object")
mode = cred.get("mode")
if mode not in ("persistent", "persistent-org"):
    die("github-runner: credential mode %s is not supported by this version" % mode)
fields = []
for key in ("url", "token", "name"):
    value = cred.get(key)
    if not isinstance(value, str) or not value:
        die("github-runner start: the JSON registration has no %s" % key)
    fields.append(value)
# https, a host with an optional port, then exactly one path segment (the org) and
# at most one trailing slash; no query or fragment. Kept as one pattern so the ps1
# check is the same expression.
org_url = r"https://[A-Za-z0-9.-]+(:[0-9]+)?/[^/?#]+/?"
if mode == "persistent-org" and not re.fullmatch(org_url, fields[0]):
    die("github-runner start: a persistent-org credential url must be https://<host>/<org>")
labels = cred.get("labels") or []
if not isinstance(labels, list) or not all(isinstance(l, str) and l for l in labels):
    die("github-runner start: the JSON registration labels must be a list of names")
if not labels:
    die("github-runner start: the JSON registration has no labels")
if any("," in l for l in labels):
    die("github-runner start: a JSON registration label contains a comma")
fields.append(",".join(labels))
if any("\n" in f or "\r" in f for f in fields):
    die("github-runner start: a JSON registration field contains a line break")
print("\n".join(fields))
'
}

github_api_path() {
	case "$repo_url" in
	https://github.com/*) ;;
	*) fail "--url must start with https://github.com/" ;;
	esac
	path=${repo_url#https://github.com/}
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

# Every label in the comma-separated $labels, in one body. json.dumps, so a label
# with a quote or a backslash in it cannot break the body.
label_payload() {
	python3 -c 'import json,sys; print(json.dumps({"labels": sys.argv[1].split(",")}))' "$labels"
}

# Puts the labels back. stop-github-runner.sh takes them off through the API so
# the queue stops routing work here during a drain, and the registration itself
# outlives every stop reason but `terminate` — so a drained runner would otherwise
# come back online carrying only its default labels, and `runs-on: <label>` would
# never match it again: healthy-looking, and silently never given another job.
# POST .../labels adds without replacing, so this is safe to run whether the
# config.sh above just passed --labels or the registration was already there.
#
# Every step fails explicitly, because the caller runs this in a subshell whose
# failure is only logged: a runner with no labels still beats one that will not
# start.
ensure_labels() {
	github_token=$(token_value) || exit 1
	api_path=$(github_api_path) || exit 1
	runner_id=$(find_runner_id) || fail "failed to list runners name=$runner_name"
	[ -n "$runner_id" ] || fail "runner is not registered name=$runner_name"
	curl -fsSL -X POST -o /dev/null \
		-H "Accept: application/vnd.github+json" \
		-H "Content-Type: application/json" \
		-H "Authorization: token $github_token" \
		-d "$(label_payload)" \
		"https://api.github.com/$api_path/actions/runners/$runner_id/labels" ||
		fail "label request failed name=$runner_name id=$runner_id labels=$labels"
	note "labels ensured name=$runner_name id=$runner_id labels=$labels"
}

# setpriv, never su or runuser: those start a new session, which would take the
# runner out of this script's process group, so a signal sent to the group would
# miss it. The account has no home directory, so HOME points at the runner
# directory it owns.
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
	setpriv --reuid="$service_user" --regid="$service_user" --init-groups \
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

# The runner name is the host name. Its labels are --labels, parsed above.
runner_name=$(hostname)

# `.runner` is the file config.sh writes when a directory has been configured; it
# and the `.credentials` beside it are this machine's identity. Absent means the
# machine has none yet — a fresh install, or the first start on a copy of an
# installed disk, which carries the unpacked runner but deliberately no identity —
# so register. Present means an ordinary service restart, and config.sh refuses an
# already-configured directory, so registration is skipped and the same identity
# is reused. With a personal access token, stopped-github-runner.sh's
# `config.sh remove` deletes `.runner`, which is what makes a
# terminated-then-restarted install register again rather than start
# unconfigured.
#
# A JSON registration carries its own url — a repository or, in the
# persistent-org mode, an organization — runner name and labels, and the token in
# it is already a registration token, so it goes to config.sh as is; --url, the
# host name and --labels are not used for it. An absent token is not fatal here:
# a runner with `.runner` starts without one, and the PAT registration below fails
# on it by name.
credential=$(token_value 2>/dev/null) || credential=
if is_minted "$credential"; then
	minted=yes
else
	minted=no
fi

if [ -f .runner ]; then
	registered=$(registered_name)
	runner_name=${registered:-$runner_name}
	note "already registered; reusing this machine's identity name=$runner_name dir=$work_dir"
elif [ "$minted" = yes ]; then
	registration=$(printf '%s' "$credential" | minted_registration) || exit 1
	minted_url=$(printf '%s\n' "$registration" | sed -n 1p)
	minted_token=$(printf '%s\n' "$registration" | sed -n 2p)
	runner_name=$(printf '%s\n' "$registration" | sed -n 3p)
	labels=$(printf '%s\n' "$registration" | sed -n 4p)

	# Only the registration's labels, none of GitHub's defaults: a job elsewhere in
	# the repository or organization that asks for `self-hosted`, an OS or an
	# architecture must not land on a runner meant only for these labels.
	set -- --unattended --url "$minted_url" --token "$minted_token" --name "$runner_name" \
		--no-default-labels --labels "$labels" --replace

	note "registering with the JSON registration name=$runner_name labels=$labels user=$service_user"
	as_service_user ./config.sh "$@"
else
	[ -n "$repo_url" ] || fail "--url is required"
	github_token=$(token_value)
	api_path=$(github_api_path)

	# A registration token is short-lived, so it is requested at the moment it is
	# used and never persisted.
	registration_json=$(curl -fsSL -X POST \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: token $github_token" \
		"https://api.github.com/$api_path/actions/runners/registration-token") ||
		fail "failed to create registration token"
	registration_token=$(printf '%s' "$registration_json" | json_field token)
	[ -n "$registration_token" ] || fail "failed to create registration token"

	set -- --name "$runner_name" --url "$repo_url" --token "$registration_token" --unattended --replace
	if [ -n "$labels" ]; then
		set -- "$@" --labels "$labels"
	fi

	note "registering name=$runner_name labels=$labels user=$service_user"
	as_service_user ./config.sh "$@"
fi

# Runs on both PAT paths, and never fatally: the subshell contains a hard failure
# from anything inside, so the listener starts either way. A JSON registration
# set its labels at registration and holds no API credential, so there is nothing
# to restore: stop leaves them alone too.
if [ "$minted" = yes ]; then
	note "labels were set at registration; no label upkeep name=$runner_name"
elif [ -z "$labels" ]; then
	note "no labels to ensure name=$runner_name"
else
	(ensure_labels) ||
		warn "could not ensure the labels; starting without them name=$runner_name labels=$labels"
fi

note "starting the listener name=$runner_name dir=$work_dir"
exec setpriv --reuid="$service_user" --regid="$service_user" --init-groups \
	env HOME="$work_dir" ./run.sh
