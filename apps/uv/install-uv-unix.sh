#!/bin/sh
set -eu

err_unsupported() {
	echo "uv installation not supported on this platform: $*" >&2
	exit 1
}

case "$(uname -s)" in
Linux)
	if [ "$(id -u)" -ne 0 ]; then
		echo "uv installation on Linux requires root privileges" >&2
		exit 1
	fi
	;;
Darwin) ;;
*) err_unsupported "$(uname -s)" ;;
esac

case "$(uname -m)" in
x86_64 | amd64 | aarch64 | arm64) ;;
*) err_unsupported "architecture $(uname -m)" ;;
esac

if [ -x /usr/local/bin/uv ]; then
	/usr/local/bin/uv --version
	exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
	echo "curl is required to install uv" >&2
	exit 1
fi

curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL="/usr/local/bin" sh

/usr/local/bin/uv --version
