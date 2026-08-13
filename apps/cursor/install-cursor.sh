#!/bin/sh
set -eu

fail() {
	echo "cursor install: $*" >&2
	exit 1
}

# The installed `agent` command is a wrapper script that dereferences HOME;
# agent-run phases execute without one, so pin it to the install prefix.
export HOME=${HOME:-${CURSOR_INSTALL_HOME:-/opt/cursor}}

if command -v agent >/dev/null 2>&1 && [ -z "${CURSOR_FORCE_INSTALL:-}" ]; then
	agent --version
	exit 0
fi
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v bash >/dev/null 2>&1 || fail "bash is required"

case "$(uname -s)" in
Linux | Darwin) ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac
case "$(uname -m)" in
x86_64 | amd64 | aarch64 | arm64) ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

# The official installer lays everything out under $HOME/.local. Install
# environments may run without HOME, and a per-user home would hide the CLI
# from every other user, so pin the install to a world-readable prefix and
# expose the binary on the global PATH.
install_home=${CURSOR_INSTALL_HOME:-/opt/cursor}
bin_dir=${CURSOR_BIN_DIR:-/usr/local/bin}
case "$install_home" in
"" | /) fail "unsafe CURSOR_INSTALL_HOME: $install_home" ;;
esac
mkdir -p "$install_home" "$bin_dir"
chmod 755 "$install_home"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
echo "Downloading the official Cursor CLI installer" >&2
curl -fsSL https://cursor.com/install -o "$tmp/install.sh"
HOME=$install_home bash "$tmp/install.sh"

agent_bin="$install_home/.local/bin/agent"
[ -x "$agent_bin" ] || fail "official installer did not create the agent command"
ln -sf "$agent_bin" "$bin_dir/agent"
if [ -x "$install_home/.local/bin/cursor-agent" ]; then
	ln -sf "$install_home/.local/bin/cursor-agent" "$bin_dir/cursor-agent"
fi
HOME=$install_home "$bin_dir/agent" --version
