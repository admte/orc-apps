#!/bin/sh
set -eu

# Starts the runner for the credential in --job-file and exits as it does.
#
# - {"mode":"persistent","token":"glrt-…"}: a runner that takes jobs until it is
#   stopped (`gitlab-runner run`), one runner manager on this machine.
# - one job as GitLab hands it to a runner: the job runs once, served to the
#   runner from a proxy on loopback, and the exit status is the job's outcome:
#   0 success, 1 failed, 2 canceled, 3 ended by GitLab.
#
# The runner's config.toml is written here, at every start, into a root-only
# directory under /run, and never at install: an installed disk may be copied.
# The credential is read by the helper alone; no shell variable or command line
# carries it.

RUN_DIR=/run/gitlab-runner

usage() {
	cat <<'USAGE'
Usage: start-gitlab-runner.sh --url=URL --job-file=PATH [--ca-file=PATH]
                              [--ephemeral=true|false] [--user=NAME]

Runs GitLab Runner for the credential in --job-file. Run as root from the
directory install ran in.

  --url=URL          GitLab's address, e.g. https://gitlab.com
  --job-file=PATH    file holding {"mode":"persistent","token":"glrt-…"}, or one
                     job as GitLab hands it to a runner
  --ca-file=PATH     PEM certificate GitLab's address is signed by; added to the
                     system's trust store
  --ephemeral=BOOL   true for one job, false for a runner token (default false)
  --user=NAME        account jobs run as (default: gitlab-runner)
  --help             show this help
USAGE
}

fail() {
	echo "gitlab-runner start: $*" >&2
	exit 1
}

usage_error() {
	echo "gitlab-runner start: $*" >&2
	usage >&2
	exit 2
}

note() {
	echo "gitlab-runner start: $*"
}

url=
job_file=
ca_file=
ephemeral=false
user=gitlab-runner
for arg; do
	case $arg in
	--url=*) url=${arg#--url=} ;;
	--job-file=*) job_file=${arg#--job-file=} ;;
	--ca-file=*) ca_file=${arg#--ca-file=} ;;
	--ephemeral=*) ephemeral=${arg#--ephemeral=} ;;
	--user=*) user=${arg#--user=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$url" ] || usage_error "--url is required"
[ -n "$job_file" ] || usage_error "--job-file is required"
[ -n "$user" ] || usage_error "--user must not be empty"
[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ -x ./gitlab-runner ] && [ -x ./gitlab-runner-handover ] ||
	fail "no runner install found; install must run first dir=$(pwd)"
home=$(getent passwd "$user" | cut -d: -f6)
[ -n "$home" ] || fail "no account $user; install must run first"

# The CA goes into the system's trust store, which git, artifact transfers and
# a job's own tools such as curl read.
if [ -n "$ca_file" ]; then
	[ -s "$ca_file" ] || fail "--ca-file is empty or missing"
	if command -v update-ca-certificates >/dev/null 2>&1 && [ -d /usr/local/share/ca-certificates ]; then
		install -m 0644 "$ca_file" /usr/local/share/ca-certificates/gitlab-runner-ca.crt
		update-ca-certificates >/dev/null
	elif command -v update-ca-trust >/dev/null 2>&1; then
		install -m 0644 "$ca_file" /etc/pki/ca-trust/source/anchors/gitlab-runner-ca.pem
		update-ca-trust extract
	elif command -v update-ca-certificates >/dev/null 2>&1 && [ -d /etc/pki/trust/anchors ]; then
		install -m 0644 "$ca_file" /etc/pki/trust/anchors/gitlab-runner-ca.pem
		update-ca-certificates >/dev/null
	else
		fail "no tool to add --ca-file to the system's trust store"
	fi
	note "added the CA to the system's trust store"
fi

# What an earlier start left, a config with a token included, goes first.
rm -rf "$RUN_DIR"
(umask 077 && mkdir -p "$RUN_DIR")

set -- start --job-file="$job_file" --url="$url" --ephemeral="$ephemeral" \
	--runner="$(pwd)/gitlab-runner" --dir="$RUN_DIR" --user="$user" --home="$home"
[ -z "$ca_file" ] || set -- "$@" --ca="$ca_file"

note "starting url=$url ephemeral=$ephemeral user=$user"
# exec: the stop signal reaches the helper, which passes it to the runner.
exec ./gitlab-runner-handover "$@"
