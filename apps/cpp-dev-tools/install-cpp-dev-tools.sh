#!/bin/sh
set -eu

err_unsupported() {
	echo "cpp-dev-tools is not supported on this Linux distribution: $*" >&2
	exit 1
}

case "$(uname -s)" in
Linux) ;;
*) err_unsupported "not Linux" ;;
esac

run_as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo -n "$@"
	else
		echo "root privileges are required; run as root or install sudo" >&2
		exit 1
	fi
}

if command -v apt-get >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	if [ "$(id -u)" -eq 0 ]; then
		apt-get update
		apt-get install -y build-essential
	else
		sudo -n --preserve-env=DEBIAN_FRONTEND apt-get update
		sudo -n --preserve-env=DEBIAN_FRONTEND apt-get install -y build-essential
	fi
elif command -v dnf >/dev/null 2>&1; then
	run_as_root dnf install -y gcc gcc-c++ make
elif command -v yum >/dev/null 2>&1; then
	run_as_root yum install -y gcc gcc-c++ make
elif command -v apk >/dev/null 2>&1; then
	run_as_root apk add --no-cache build-base
elif command -v pacman >/dev/null 2>&1; then
	run_as_root pacman -Syu --noconfirm --needed base-devel
elif command -v zypper >/dev/null 2>&1; then
	run_as_root zypper --non-interactive install -t pattern devel_C_C++
else
	err_unsupported "no supported package manager found (apt-get, dnf, yum, apk, pacman, zypper)"
fi
