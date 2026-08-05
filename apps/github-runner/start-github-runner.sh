#!/bin/sh
set -eu

SERVICE_USER=${SERVICE_USER:-ghrunner}

work_dir=${WORK_DIR:-github-runner}
if [ ! -x "$work_dir/run.sh" ]; then
	echo "github-runner start: $work_dir/run.sh not found; run install first" >&2
	exit 1
fi

work_dir=$(CDPATH= cd -- "$work_dir" && pwd)

shell_quote() {
	printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/"
}

# The runner refuses to execute as root, so hand off to the service account
# created during install. When already unprivileged, run in place.
if [ "$(id -u)" -eq 0 ]; then
	id "$SERVICE_USER" >/dev/null 2>&1 ||
		{
			echo "github-runner start: service user $SERVICE_USER is missing; run install first" >&2
			exit 1
		}
	quoted=$(shell_quote "$work_dir")
	exec su -s /bin/sh "$SERVICE_USER" \
		-c "HOME=$quoted; export HOME; cd $quoted && exec ./run.sh"
fi

cd "$work_dir"
exec ./run.sh
