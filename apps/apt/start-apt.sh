#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: start-apt.sh [--packages=LIST]

Installs the Debian or Ubuntu packages in LIST with apt-get, after the checks
install-apt.sh makes.

  --packages=LIST  space-separated package names, e.g. "git curl htop"
  --help           show this help
USAGE
}

usage_error() {
	echo "apt start: $*" >&2
	usage >&2
	exit 2
}

packages=
for arg; do
	case $arg in
	--packages=*) packages=${arg#--packages=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
sh "$script_dir/install-apt.sh" --packages="$packages"

if [ -z "$(printf '%s' "$packages" | tr -d '[:space:]')" ]; then
	echo "No APT packages specified; nothing to install"
	exit 0
fi

export DEBIAN_FRONTEND=noninteractive

run_apt() {
	if [ "$(id -u)" -eq 0 ]; then
		apt-get "$@"
	else
		sudo -n --preserve-env=DEBIAN_FRONTEND apt-get "$@"
	fi
}

run_apt update
# shellcheck disable=SC2086
run_apt install -y $packages
