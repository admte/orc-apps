#!/bin/sh
set -eu

fail() {
	echo "claude configure: $*" >&2
	exit 1
}

if command -v claude >/dev/null 2>&1; then
	claude_bin=$(command -v claude)
elif [ -n "${CLAUDE_INSTALL_DIR:-}" ] && [ -x "$CLAUDE_INSTALL_DIR/claude" ]; then
	claude_bin=$CLAUDE_INSTALL_DIR/claude
elif [ -x /usr/local/bin/claude ]; then
	claude_bin=/usr/local/bin/claude
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/claude" ]; then
	claude_bin=$HOME/.local/bin/claude
else
	fail "Claude Code is not installed"
fi
"$claude_bin" --version >/dev/null

key_file=${ANTHROPIC_API_KEY_FILE:-}
if [ -z "$key_file" ]; then
	echo "Claude Code is ready; Anthropic API key was not provided" >&2
	exit 0
fi
[ -r "$key_file" ] || fail "ANTHROPIC_API_KEY_FILE is not readable"
[ -n "${HOME:-}" ] || fail "HOME is required to configure Claude Code"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to update Claude settings"

config_dir=${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
settings_file="$config_dir/settings.json"
mkdir -p "$config_dir"
umask 077

python3 - "$settings_file" "$key_file" <<'PY'
import json
import os
import sys
import tempfile

settings_path, key_path = sys.argv[1:]
with open(key_path, encoding="utf-8") as source:
    key = source.read().rstrip("\r\n")
if not key:
    raise SystemExit("anthropic_api_key is empty")

if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as source:
        settings = json.load(source)
else:
    settings = {}
if not isinstance(settings, dict):
    raise SystemExit("Claude settings must be a JSON object")

env = settings.setdefault("env", {})
if not isinstance(env, dict):
    raise SystemExit("Claude settings env must be a JSON object")
env["ANTHROPIC_API_KEY"] = key

fd, temporary = tempfile.mkstemp(prefix=".settings.", dir=os.path.dirname(settings_path))
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(settings, output, indent=2, ensure_ascii=False)
        output.write("\n")
    os.replace(temporary, settings_path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY

echo "Claude Code API key configured" >&2
