#!/bin/sh
set -eu

# Once the runner has stopped, however it stopped: kills whatever jobs left
# running (a job runs in a session of its own, outside the service's
# processes) and removes the runner's config, which may hold a runner token.

user=gitlab-runner
for arg; do
	case $arg in
	--user=*) user=${arg#--user=} ;;
	--help)
		echo "Usage: stopped-gitlab-runner.sh [--user=NAME]"
		echo "Kills every process of the job account (default gitlab-runner) and removes"
		echo "the runner's configuration from /run/gitlab-runner. Run as root."
		exit 0
		;;
	*) echo "gitlab-runner stopped: unknown argument $arg" >&2; exit 2 ;;
	esac
done

status=0
./gitlab-runner-handover end-jobs --user="$user" || status=1
rm -rf /run/gitlab-runner
echo "gitlab-runner stopped: ended the jobs of $user and removed the runner's configuration"
exit "$status"
