#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-cursor.sh [--force] [--install-home=DIR] [--bin-dir=DIR]

Installs the Cursor CLI with Cursor's official installer into a world-readable
prefix and links its agent command onto PATH. Leaves an agent command that is
already on PATH as it is.

  --force             install even when agent is already on PATH
  --install-home=DIR  prefix the installer lays the CLI out under (default: /opt/cursor)
  --bin-dir=DIR       where the agent command is linked (default: /usr/local/bin)
  --help              show this help
USAGE
}

fail() {
	echo "cursor install: $*" >&2
	exit 1
}

usage_error() {
	echo "cursor install: $*" >&2
	usage >&2
	exit 2
}

force=
install_home=/opt/cursor
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--force) force=1 ;;
	--install-home=*) install_home=${arg#--install-home=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$bin_dir" ] || usage_error "--bin-dir must not be empty"

if command -v agent >/dev/null 2>&1 && [ -z "$force" ]; then
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

# The official installer lays everything out under $HOME/.local, and a
# per-user home (root's is 0700) would hide the CLI from every other user,
# so pin the install to a world-readable prefix and expose the binary on
# the global PATH.
case "$install_home" in
"" | /) fail "unsafe --install-home: $install_home" ;;
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
