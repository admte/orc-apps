#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-apt.sh [--packages=LIST]

Checks that this machine is Debian or Ubuntu with apt-get, and that every name
in LIST is a valid package name. Installs nothing.

  --packages=LIST  space-separated package names, e.g. "git curl htop"
  --help           show this help
USAGE
}

usage_error() {
	echo "apt install: $*" >&2
	usage >&2
	exit 2
}

packages_arg=
for arg; do
	case $arg in
	--packages=*) packages_arg=${arg#--packages=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

err_unsupported() {
	echo "apt supported only on Debian/Ubuntu with apt-get available: $*" >&2
	exit 1
}

case "$(uname -s)" in
Linux) ;;
*) err_unsupported "not Linux" ;;
esac

if [ ! -r /etc/os-release ]; then
	echo "read os-release: /etc/os-release not readable" >&2
	exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

debian_like=0
id_lower=$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')
case "$id_lower" in
debian | ubuntu) debian_like=1 ;;
esac

if [ "$debian_like" -eq 0 ] && [ -n "${ID_LIKE:-}" ]; then
	for like in $ID_LIKE; do
		like_lower=$(printf '%s' "$like" | tr '[:upper:]' '[:lower:]')
		case "$like_lower" in
		debian | ubuntu)
			debian_like=1
			break
			;;
		esac
	done
fi

if [ "$debian_like" -eq 0 ]; then
	err_unsupported "detected id=${ID:-} id_like=${ID_LIKE:-}"
fi

if [ -x /usr/bin/apt-get ]; then
	:
elif command -v apt-get >/dev/null 2>&1; then
	:
else
	echo "locate apt-get: not found" >&2
	exit 1
fi

packages=$(printf '%s' "$packages_arg" | tr -d '[:space:]')
if [ -z "$packages" ]; then
	exit 0
fi

for pkg in $packages_arg; do
	if ! printf '%s\n' "$pkg" | grep -Eq '^[a-z0-9][a-z0-9+.-]*$'; then
		echo "invalid package name \"$pkg\"" >&2
		exit 1
	fi
done
