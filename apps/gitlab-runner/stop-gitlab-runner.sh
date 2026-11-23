#!/bin/sh
set -eu

# Stops the runner gracefully before the service is stopped: SIGQUIT to the
# runner's main process alone lets the job in flight finish, then this waits
# for that process to exit and ends whatever the job left running. The
# service's own stop signal goes to every process of the service, jobs
# included, and is followed by a kill after a short grace; by the time it is
# sent here, nothing is left for it.

usage() {
	cat <<'USAGE'
Usage: stop-gitlab-runner.sh --pid=PID [--timeout=SECONDS] [--user=NAME]

Asks the runner (process PID) to finish its job and exit, waits for it, then
kills every process left of the account jobs run as. Run as root.

  --pid=PID          the runner's main process
  --timeout=SECONDS  longest wait for the job in flight (default: 3540)
  --user=NAME        account jobs run as (default: gitlab-runner)
  --help             show this help
USAGE
}

fail() {
	echo "gitlab-runner stop: $*" >&2
	exit 1
}

usage_error() {
	echo "gitlab-runner stop: $*" >&2
	usage >&2
	exit 2
}

note() {
	echo "gitlab-runner stop: $*"
}

pid=
timeout=3540
user=gitlab-runner
for arg; do
	case $arg in
	--pid=*) pid=${arg#--pid=} ;;
	--timeout=*) timeout=${arg#--timeout=} ;;
	--user=*) user=${arg#--user=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
case $pid in '' | *[!0-9]* | 0) usage_error "--pid must be a process id" ;; esac
case $timeout in '' | *[!0-9]*) usage_error "--timeout must be a number of seconds" ;; esac

if kill -QUIT "$pid" 2>/dev/null; then
	note "asked the runner to finish its job and exit pid=$pid"
	waited=0
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$waited" -ge "$timeout" ]; then
			note "the runner is still running after ${timeout}s; leaving it to the service stop"
			exit 0
		fi
		sleep 1
		waited=$((waited + 1))
	done
	note "the runner exited after ${waited}s"
else
	note "the runner is not running pid=$pid"
fi

# A job runs in a session of its own, outside the service's processes.
./gitlab-runner-handover end-jobs --user="$user" || fail "could not end the jobs of $user"
note "ended every process of $user"
