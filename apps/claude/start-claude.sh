#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: start-claude.sh [--api-key-file=PATH] [--install-dir=DIR]

Checks that Claude Code runs and, given a key file, writes the Anthropic API key
into Claude Code's user settings.

  --api-key-file=PATH  file holding the Anthropic API key
  --install-dir=DIR    where install put the claude command (default: /usr/local/bin)
  --help               show this help
USAGE
}

fail() {
	echo "claude configure: $*" >&2
	exit 1
}

usage_error() {
	echo "claude configure: $*" >&2
	usage >&2
	exit 2
}

key_file=
install_dir=/usr/local/bin
for arg; do
	case $arg in
	--api-key-file=*) key_file=${arg#--api-key-file=} ;;
	--install-dir=*) install_dir=${arg#--install-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

if command -v claude >/dev/null 2>&1; then
	claude_bin=$(command -v claude)
elif [ -x "$install_dir/claude" ]; then
	claude_bin=$install_dir/claude
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/claude" ]; then
	claude_bin=$HOME/.local/bin/claude
else
	fail "Claude Code is not installed"
fi
"$claude_bin" --version >/dev/null

if [ -z "$key_file" ]; then
	echo "Claude Code is ready; Anthropic API key was not provided" >&2
	exit 0
fi
[ -r "$key_file" ] || fail "the API key file is not readable"
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
