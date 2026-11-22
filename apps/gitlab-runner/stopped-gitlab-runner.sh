#!/bin/sh
set -eu

# Removes the runner's config, which may hold a runner token, once the runner
# has stopped, however it stopped.

case ${1:-} in
--help)
	echo "Usage: stopped-gitlab-runner.sh"
	echo "Removes the runner's configuration from /run/gitlab-runner. Run as root."
	exit 0
	;;
'') ;;
*) echo "gitlab-runner stopped: unknown argument $1" >&2; exit 2 ;;
esac

rm -rf /run/gitlab-runner
echo "gitlab-runner stopped: removed the runner's configuration"
