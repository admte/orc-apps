#!/bin/sh
set -eu

# Start phase: the runner is node identity, so it is created here — once per node,
# every time a node that has none comes up — and never in install, whose output a
# pool bake snapshots into an image every clone shares. Install leaves the binary
# with no config.toml; this script creates the node's own runner in GitLab, writes
# its authentication token into config.toml, then becomes the runner.

SERVICE_USER=${SERVICE_USER:-gitlab-runner}

fail() {
	echo "gitlab-runner start: $*" >&2
	exit 1
}

note() {
	echo "gitlab-runner start: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

token_value() {
	if [ -n "${TOKEN_FILE:-}" ]; then
		tr -d '\r\n' <"$TOKEN_FILE"
	elif [ -n "${TOKEN:-}" ]; then
		printf '%s' "$TOKEN"
	else
		echo ''
	fi
}

json_field() {
	python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$1"
}

# The instance the API and the runner talk to, taken from the configured URL:
# https://gitlab.example.com/group/project -> https://gitlab.example.com
gitlab_base() {
	rest=${URL#https://}
	host=${rest%%/*}
	printf 'https://%s' "$host"
}

# The namespace the runner belongs to: everything after the host. Empty means the
# instance itself, which is an instance runner and needs an administrator token.
gitlab_namespace() {
	rest=${URL#https://}
	case "$rest" in
	*/*) path=${rest#*/} ;;
	*) path='' ;;
	esac
	# Trailing slash first: a clone URL pasted as .../project.git/ would otherwise
	# keep its .git and resolve to a namespace that does not exist.
	while :; do
		case "$path" in
		*/) path=${path%/} ;;
		*) break ;;
		esac
	done
	path=${path%.git}
	printf '%s' "$path"
}

# The access token never reaches curl's argv: /proc/<pid>/cmdline is world
# readable, so a flag would show a token that can create and delete runners to
# every job this node later runs. curl reads it from a config on stdin instead.
api_call() {
	method=$1
	path=$2
	shift 2
	printf 'header = "PRIVATE-TOKEN: %s"\n' "$gitlab_token" |
		curl -fsSL -K - -X "$method" "$@" "$api/$path"
}

# The HTTP status of a GET, so a definite "no such runner" can be told apart from
# a lookup that merely failed.
api_status() {
	printf 'header = "PRIVATE-TOKEN: %s"\n' "$gitlab_token" |
		curl -sS -K - -o /dev/null -w '%{http_code}' "$api/$1" 2>/dev/null
}

# An administrator can delete the runner in GitLab while config.toml still names
# it. The runner would then fail authentication on every restart and never take a
# job, so the local state is dropped and a new runner created. Only a definite 404
# does this: a lookup that fails, or a token without the scope to look, keeps the
# runner this node already has.
runner_gone() {
	[ -s "$id_file" ] || return 1
	[ "$(api_status "runners/$(cat "$id_file")")" = 404 ]
}

# A project path is a single path-encoded segment for the API, so every slash in
# it has to be escaped: group/subgroup/project -> group%2Fsubgroup%2Fproject.
url_encode() {
	python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Prints "<runner_type> <id_field> <id>" for the configured namespace. A project
# wins over a group of the same path, which is what the URL means to a person.
resolve_target() {
	namespace=$(gitlab_namespace)
	if [ -z "$namespace" ]; then
		printf 'instance_type  \n'
		return 0
	fi
	encoded=$(url_encode "$namespace")
	if body=$(api_call GET "projects/$encoded" 2>/dev/null); then
		id=$(printf '%s' "$body" | json_field id)
		if [ -n "$id" ]; then
			printf 'project_type project_id %s\n' "$id"
			return 0
		fi
	fi
	if body=$(api_call GET "groups/$encoded" 2>/dev/null); then
		id=$(printf '%s' "$body" | json_field id)
		if [ -n "$id" ]; then
			printf 'group_type group_id %s\n' "$id"
			return 0
		fi
	fi
	fail "no project or group at $namespace, or the token cannot see it"
}

# Puts the runner back into rotation. stop-gitlab-runner pauses it through the API
# so the queue stops routing work here during a drain, and the runner outlives
# every stop reason but `terminate` — so a drained node would otherwise come back
# online paused: healthy-looking, and silently never given another job. Never
# fatal, the same way github-runner's label is not: a runner that has to be
# resumed by hand still beats a node that will not start.
resume_runner() {
	[ -s "$id_file" ] || {
		note "no runner id recorded; nothing to resume"
		return 0
	}
	runner_id=$(cat "$id_file")
	api_call PUT "runners/$runner_id" -o /dev/null --data-urlencode "paused=false" ||
		return 1
	note "runner resumed id=$runner_id"
}

need curl
need hostname
need python3

# By path, not through PATH: a service environment is not a login shell, and
# /usr/local/bin is not guaranteed to be on root's PATH. The version is the one
# this app instance was installed as — `current` belongs to whichever version was
# installed last, which on a node carrying two of them is somebody else's.
root=${GITLAB_RUNNER_INSTALL_ROOT:-/opt/gitlab-runner}
if [ -n "${APP_VERSION:-}" ] && [ -x "$root/$APP_VERSION/gitlab-runner" ]; then
	runner="$root/$APP_VERSION/gitlab-runner"
else
	runner="$root/current/gitlab-runner"
fi
[ -x "$runner" ] || fail "no runner install found; install must run first path=$runner"

[ -n "${URL:-}" ] || fail "URL is required"
case "$URL" in
https://*) ;;
*) fail "URL must start with https://" ;;
esac
gitlab_token=$(token_value)
[ -n "$gitlab_token" ] || fail "TOKEN_FILE or TOKEN is required"
api=$(gitlab_base)/api/v4

work_dir=gitlab-runner
mkdir -p "$work_dir/builds"
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)
config="$work_dir/config.toml"
builds="$work_dir/builds"
id_file="$work_dir/runner.id"
# Owner only: the account's primary group is the distribution's business, and a
# `user:user` pair would assume a group useradd is merely conventional about.
chown -R "$SERVICE_USER" "$builds" ||
	fail "cannot give $builds to $SERVICE_USER; install must run first"

# The runner's description is the host name (a pool member is `<pool>-<slot>`),
# and its tag is the pool name from the `pool.name` x-source, so `tags: [<pool>]`
# in .gitlab-ci.yml routes to this pool the way `runs-on: <pool>` does on GitHub.
# Without a pool name there is nothing to route on, so the runner takes untagged
# jobs instead of sitting idle.
runner_name=$(hostname)
tags=${POOL:-}
executor=${EXECUTOR:-shell}

# A `[[runners]]` section is what `register` writes, and it carries this node's
# authentication token. Present means an ordinary service restart, so the same
# runner is reused; absent means a fresh install, or the first boot of a clone
# whose baked image deliberately carries none. The stopped hook deletes the runner
# and removes config.toml, which is what makes a terminated-then-restarted node
# create a new one rather than start against a runner GitLab no longer has.
if grep -q '^\[\[runners\]\]' "$config" 2>/dev/null && runner_gone; then
	note "the runner is gone from GitLab; creating a new one name=$runner_name"
	rm -f "$config" "$id_file"
fi

if grep -q '^\[\[runners\]\]' "$config" 2>/dev/null; then
	note "already registered; reusing this node's runner name=$runner_name"
	(resume_runner) || note "could not resume the runner; starting anyway name=$runner_name"
else
	target=$(resolve_target)
	runner_type=$(printf '%s' "$target" | awk '{ print $1 }')
	id_field=$(printf '%s' "$target" | awk '{ print $2 }')
	target_id=$(printf '%s' "$target" | awk '{ print $3 }')
	note "creating the runner name=$runner_name type=$runner_type tags=$tags"

	set -- --data-urlencode "runner_type=$runner_type" \
		--data-urlencode "description=$runner_name"
	[ -z "$id_field" ] || set -- "$@" --data-urlencode "$id_field=$target_id"
	if [ -n "$tags" ]; then
		set -- "$@" --data-urlencode "tag_list=$tags"
	else
		set -- "$@" --data-urlencode "run_untagged=true"
	fi

	created=$(api_call POST "user/runners" "$@") ||
		fail "failed to create the runner name=$runner_name type=$runner_type"
	runner_id=$(printf '%s' "$created" | json_field id)
	runner_token=$(printf '%s' "$created" | json_field token)
	[ -n "$runner_id" ] && [ -n "$runner_token" ] ||
		fail "GitLab returned no runner token name=$runner_name"

	# The id is what stop and stopped use to pause and delete this runner; the
	# token GitLab returns here cannot be read back, so config.toml is its only
	# other copy.
	(umask 077 && printf '%s' "$runner_id" >"$id_file")

	# The token goes through the environment, never a flag: a flag would show the
	# runner's credential in the process list to every job it later runs.
	if ! CI_SERVER_URL="$(gitlab_base)" \
		CI_SERVER_TOKEN="$runner_token" \
		REGISTER_NON_INTERACTIVE=true \
		"$runner" register \
		--config "$config" \
		--name "$runner_name" \
		--executor "$executor"; then
		# The runner exists in GitLab but this node cannot use it. Left behind, it
		# would be orphaned there, and the orchestrator's next start attempt would
		# create another one: a crash loop would fill the runners list.
		api_call DELETE "runners/$runner_id" -o /dev/null ||
			note "could not delete the runner after a failed registration id=$runner_id"
		rm -f "$id_file"
		fail "registration failed name=$runner_name id=$runner_id"
	fi
	note "runner created and registered name=$runner_name id=$runner_id"
fi

# The runner authenticates with the token config.toml holds, not with this one,
# and every job it runs inherits its environment — so the access token stops here.
note "starting the runner name=$runner_name config=$config"
exec env -u TOKEN_FILE -u TOKEN "$runner" run \
	--config "$config" \
	--working-directory "$builds" \
	--user "$SERVICE_USER"
