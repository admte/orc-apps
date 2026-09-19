#!/bin/sh
set -eu

# Start phase: registration is node identity, so it happens here — once per node,
# every time a node that has none comes up — and never in install, whose output a
# pool bake snapshots into an image every clone shares. Install leaves the binary
# with no config.toml; this script gives the running node its own runner manager
# entry, then becomes the runner.

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
		fail "TOKEN_FILE or TOKEN is required"
	fi
}

need gitlab-runner
need hostname

work_dir=gitlab-runner
mkdir -p "$work_dir/builds"
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)
config="$work_dir/config.toml"
builds="$work_dir/builds"
# Owner only: the account's primary group is the distribution's business, and a
# `user:user` pair would assume a group useradd is merely conventional about.
chown -R "$SERVICE_USER" "$builds"

# The runner's description in GitLab is the host name (a pool member is
# `<pool>-<slot>`), with the pool name from the `pool.name` x-source appended so
# the whole pool is recognisable in the runners list.
runner_name=$(hostname)
[ -z "${POOL:-}" ] || runner_name="$runner_name ($POOL)"
executor=${EXECUTOR:-shell}

# A `[[runners]]` section is what `register` writes, and it carries this node's
# runner manager identity. Present means an ordinary service restart, so the same
# identity is reused; absent means a fresh install, or the first boot of a clone
# whose baked image deliberately carries none. The stopped hook's `unregister`
# removes it, which is what makes a terminated-then-restarted node register again.
if grep -q '^\[\[runners\]\]' "$config" 2>/dev/null; then
	note "already registered; reusing this node's runner name=$runner_name"
else
	[ -n "${URL:-}" ] || fail "URL is required"
	# The token goes through the environment, never a flag: a flag would show the
	# runner's credential in the process list to every job it later runs.
	note "registering name=$runner_name executor=$executor url=$URL"
	REGISTER_NON_INTERACTIVE=true \
		CI_SERVER_URL="$URL" \
		CI_SERVER_TOKEN="$(token_value)" \
		gitlab-runner register \
		--config "$config" \
		--name "$runner_name" \
		--executor "$executor" ||
		fail "registration failed name=$runner_name url=$URL"
fi

note "starting the runner name=$runner_name config=$config"
exec gitlab-runner run \
	--config "$config" \
	--working-directory "$builds" \
	--user "$SERVICE_USER"
