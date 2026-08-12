#!/bin/sh
set -eu

fail() {
	echo "cursor install: $*" >&2
	exit 1
}

if command -v agent >/dev/null 2>&1 && [ -z "${CURSOR_FORCE_INSTALL:-}" ]; then
	agent --version
	exit 0
fi
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v bash >/dev/null 2>&1 || fail "bash is required"
[ -n "${HOME:-}" ] || fail "HOME is required"

case "$(uname -s)" in
Linux | Darwin) ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac
case "$(uname -m)" in
x86_64 | amd64 | aarch64 | arm64) ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
echo "Downloading the official Cursor CLI installer" >&2
curl -fsSL https://cursor.com/install -o "$tmp/install.sh"
bash "$tmp/install.sh"

if command -v agent >/dev/null 2>&1; then
	agent_bin=$(command -v agent)
elif [ -x "$HOME/.local/bin/agent" ]; then
	agent_bin=$HOME/.local/bin/agent
else
	fail "official installer did not create the agent command"
fi
"$agent_bin" --version
