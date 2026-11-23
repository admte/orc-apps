#!/bin/sh
set -eu

# Starts the runner for the value in --token-file and exits as it does. The
# value is told apart by its shape: one whose first non-blank character is `{`
# is a credential the host supplies, anything else a runner token.
#
# - a runner token with --ephemeral=false, or {"mode":"persistent","url":…,
#   "token":…}: a runner that takes jobs until it is stopped (`gitlab-runner
#   run`), one runner manager on this machine.
# - a runner token with --ephemeral=true: the runner takes exactly one job
#   straight from GitLab, runs it, prints its outcome and exits 0; it exits 1
#   when GitLab refuses the token or the runner cannot start.
# - {"mode":"job","url":…,"job":{…}}, with --ephemeral=true: the one job runs,
#   served to the runner from a proxy on loopback, and the exit status is the
#   job's outcome: 0 success, 1 failed, 2 canceled, 3 ended by GitLab.
#
# The runner's config.toml is written here, at every start, into a root-only
# directory under /run, and never at install: an installed disk may be copied.
# The token file is read by the helper alone; no shell variable or command line
# carries its value.

RUN_DIR=/run/gitlab-runner

usage() {
	cat <<'USAGE'
Usage: start-gitlab-runner.sh --token-file=PATH [--url=URL]
                              [--ephemeral=true|false] [--user=NAME]

Runs GitLab Runner for the value in --token-file. Run as root from the
directory install ran in.

  --url=URL          GitLab's address, e.g. https://gitlab.com; used with a
                     runner token, ignored for a JSON credential, which names
                     its own
  --token-file=PATH  file holding a runner token (glrt-…), or a credential as
                     a JSON object
  --ephemeral=BOOL   true for one job, false for a runner that takes jobs until
                     stopped (default false)
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
token_file=
ephemeral=false
user=gitlab-runner
for arg; do
	case $arg in
	--url=*) url=${arg#--url=} ;;
	--token-file=*) token_file=${arg#--token-file=} ;;
	--ephemeral=*) ephemeral=${arg#--ephemeral=} ;;
	--user=*) user=${arg#--user=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$token_file" ] || usage_error "--token-file is required"
[ -n "$user" ] || usage_error "--user must not be empty"
[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ -x ./gitlab-runner ] && [ -x ./gitlab-runner-handover ] ||
	fail "no runner install found; install must run first dir=$(pwd)"
home=$(getent passwd "$user" | cut -d: -f6)
[ -n "$home" ] || fail "no account $user; install must run first"

# What an earlier start left, a config with a token included, goes first.
rm -rf "$RUN_DIR"
(umask 077 && mkdir -p "$RUN_DIR")

set -- start --token-file="$token_file" --url="$url" --ephemeral="$ephemeral" \
	--runner="$(pwd)/gitlab-runner" --dir="$RUN_DIR" --user="$user" --home="$home"

note "starting url=$url ephemeral=$ephemeral user=$user"
# exec: the stop signal reaches the helper, which passes it to the runner.
exec ./gitlab-runner-handover "$@"
