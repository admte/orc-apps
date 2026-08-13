#!/bin/sh
set -eu

fail() {
	echo "cursor start: $*" >&2
	exit 1
}

if [ -n "${CURSOR_AGENT_BIN:-}" ] && [ -x "$CURSOR_AGENT_BIN" ]; then
	agent_bin=$CURSOR_AGENT_BIN
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
key_file=${CURSOR_API_KEY_FILE:-}
if [ -z "$key_file" ]; then
	echo "Cursor CLI is ready; API key was not provided" >&2
	exit 0
fi
[ -r "$key_file" ] || fail "CURSOR_API_KEY_FILE is not readable"
CURSOR_API_KEY=$(cat "$key_file")
[ -n "$CURSOR_API_KEY" ] || fail "cursor_api_key is empty"
export CURSOR_API_KEY
"$agent_bin" status >/dev/null || fail "Cursor API key validation failed"
echo "Cursor CLI API key validated" >&2
