#!/bin/sh
set -eu

fail() {
	echo "codex configure: $*" >&2
	exit 1
}

if command -v codex >/dev/null 2>&1; then
	codex_bin=$(command -v codex)
elif [ -n "${CODEX_INSTALL_DIR:-}" ] && [ -x "$CODEX_INSTALL_DIR/codex" ]; then
	codex_bin=$CODEX_INSTALL_DIR/codex
elif [ -x /usr/local/bin/codex ]; then
	codex_bin=/usr/local/bin/codex
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/codex" ]; then
	codex_bin=$HOME/.local/bin/codex
else
	fail "Codex CLI is not installed"
fi
if [ -n "${CODEX_HOME:-}" ]; then
	umask 077
	mkdir -p "$CODEX_HOME"
fi
"$codex_bin" --version >/dev/null

key_file=${OPENAI_API_KEY_FILE:-}
if [ -z "$key_file" ]; then
	echo "Codex CLI is ready; OpenAI API key was not provided" >&2
	exit 0
fi
[ -r "$key_file" ] || fail "OPENAI_API_KEY_FILE is not readable"
[ -s "$key_file" ] || fail "openai_api_key is empty"

umask 077
"$codex_bin" login --with-api-key <"$key_file"
"$codex_bin" login status >/dev/null
echo "Codex CLI API key configured" >&2
