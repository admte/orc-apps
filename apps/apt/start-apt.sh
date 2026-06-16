#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
sh "$script_dir/install-apt.sh"

packages="${PACKAGES:-}"
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
