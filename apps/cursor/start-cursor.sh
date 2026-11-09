#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: start-cursor.sh [--api-key-file=PATH] [--agent-bin=PATH]

Checks that the Cursor CLI runs and, given a key file, that the API key
authenticates.

  --api-key-file=PATH  file holding the Cursor API key
  --agent-bin=PATH     the agent command to check (default: agent on PATH)
  --help               show this help
USAGE
}

fail() {
	echo "cursor start: $*" >&2
	exit 1
}

usage_error() {
	echo "cursor start: $*" >&2
	usage >&2
	exit 2
}

key_file=
agent_arg=
for arg; do
	case $arg in
	--api-key-file=*) key_file=${arg#--api-key-file=} ;;
	--agent-bin=*) agent_arg=${arg#--agent-bin=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

if [ -n "$agent_arg" ] && [ -x "$agent_arg" ]; then
	agent_bin=$agent_arg
elif command -v agent >/dev/null 2>&1; then
	agent_bin=$(command -v agent)
elif [ -x /usr/local/bin/agent ]; then
	agent_bin=/usr/local/bin/agent
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/agent" ]; then
	agent_bin=$HOME/.local/bin/agent
else
	fail "Cursor CLI is not installed"
fi
"$agent_bin" --version >/dev/null

# The CLI is an interactive TUI, not a service: launching it headless exits
# immediately, so start only verifies the install and, when a key is
# provided, that the key authenticates.
if [ -z "$key_file" ]; then
	echo "Cursor CLI is ready; API key was not provided" >&2
	exit 0
fi
[ -r "$key_file" ] || fail "the API key file is not readable"
CURSOR_API_KEY=$(cat "$key_file")
[ -n "$CURSOR_API_KEY" ] || fail "cursor_api_key is empty"
export CURSOR_API_KEY
"$agent_bin" status >/dev/null || fail "Cursor API key validation failed"
echo "Cursor CLI API key validated" >&2
