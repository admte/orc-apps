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

if [ -z "${APP_VERSION:-}" ] && [ -x /usr/local/bin/uv ]; then
	/usr/local/bin/uv --version
	exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
	echo "curl is required to install uv" >&2
	exit 1
fi

if [ -n "${APP_VERSION:-}" ]; then
	if ! command -v mktemp >/dev/null 2>&1; then
		echo "mktemp is required to install uv" >&2
		exit 1
	fi
	case "$(uname -s)" in
	Linux) target_os=unknown-linux-gnu ;;
	Darwin) target_os=apple-darwin ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) target_cpu=x86_64 ;;
	aarch64 | arm64) target_cpu=aarch64 ;;
	esac
	target="${target_cpu}-${target_os}"
	archive="uv-${target}.tar.gz"
	base_url="https://github.com/astral-sh/uv/releases/download/$APP_VERSION"

	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT HUP INT TERM

	echo "Downloading uv $APP_VERSION for $target" >&2
	curl -fLsS "$base_url/$archive" -o "$tmp/$archive"
	curl -fLsS "$base_url/$archive.sha256" -o "$tmp/$archive.sha256"

	expected=$(awk '{ print $1 }' "$tmp/$archive.sha256")
	[ -n "$expected" ] || {
		echo "checksum for $archive was not published" >&2
		exit 1
	}
	if command -v sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$tmp/$archive" | awk '{ print $1 }')
	elif command -v shasum >/dev/null 2>&1; then
		actual=$(shasum -a 256 "$tmp/$archive" | awk '{ print $1 }')
	else
		echo "sha256sum or shasum is required to install uv" >&2
		exit 1
	fi
	[ "$actual" = "$expected" ] || {
		echo "checksum verification failed for $archive" >&2
		exit 1
	}

	tar -xzf "$tmp/$archive" -C "$tmp"
	[ -f "$tmp/uv-$target/uv" ] || {
		echo "uv binary is missing from $archive" >&2
		exit 1
	}
	install -m 0755 "$tmp/uv-$target/uv" /usr/local/bin/uv
	install -m 0755 "$tmp/uv-$target/uvx" /usr/local/bin/uvx

	/usr/local/bin/uv --version
	exit 0
fi

curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL="/usr/local/bin" sh

/usr/local/bin/uv --version
