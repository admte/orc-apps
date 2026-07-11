#!/bin/sh
set -eu

work_dir=${WORK_DIR:-github-runner}
if [ ! -x "$work_dir/run.sh" ]; then
	echo "github-runner start: $work_dir/run.sh not found; run install first" >&2
	exit 1
fi

cd "$work_dir"
exec ./run.sh
