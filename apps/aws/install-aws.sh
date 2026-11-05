#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-aws.sh [--version=VERSION] [--force] [--install-dir=DIR]
                      [--bin-dir=DIR]

Installs the AWS CLI v2. Without --version it installs the latest release, and
leaves an aws command that is already on PATH as it is.

  --version=VERSION  AWS CLI release to install, e.g. 2.17.0
  --force            install even when aws is already on PATH
  --install-dir=DIR  where the CLI is unpacked on Linux (default: /usr/local/aws-cli)
  --bin-dir=DIR      where the aws command is linked on Linux (default: /usr/local/bin)
  --help             show this help
USAGE
}

fail() {
	echo "aws install: $*" >&2
	exit 1
}

usage_error() {
	echo "aws install: $*" >&2
	usage >&2
	exit 2
}

version=
force=
install_dir=/usr/local/aws-cli
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--version=*) version=${arg#--version=} ;;
	--force) force=1 ;;
	--install-dir=*) install_dir=${arg#--install-dir=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$install_dir" ] || usage_error "--install-dir must not be empty"
[ -n "$bin_dir" ] || usage_error "--bin-dir must not be empty"

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# Cloud images routinely ship without unzip, which the AWS CLI installer needs
# to unpack its bundle. Install it from the host package manager rather than
# failing, so a stock image works unattended.
ensure_unzip() {
	command -v unzip >/dev/null 2>&1 && return 0
	[ "$(id -u)" -eq 0 ] || fail "unzip is required and installing it needs root"
	echo "Installing unzip" >&2
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get update -qq
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q unzip
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q unzip
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive --quiet install unzip
	elif command -v apk >/dev/null 2>&1; then
		apk add --no-progress --quiet unzip
	else
		fail "unzip is required and no supported package manager was found"
	fi
	command -v unzip >/dev/null 2>&1 || fail "unzip installation failed"
}

if command -v aws >/dev/null 2>&1 && [ -z "$version" ] && [ -z "$force" ]; then
	aws --version
	exit 0
fi

need curl
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

case "$(uname -s)" in
Linux)
	ensure_unzip
	case "$(uname -m)" in
	x86_64 | amd64) arch=x86_64 ;;
	aarch64 | arm64) arch=aarch64 ;;
	*) fail "unsupported architecture: $(uname -m)" ;;
	esac

	if [ -n "$version" ]; then
		zip="awscli-exe-linux-$arch-$version.zip"
	else
		zip="awscli-exe-linux-$arch.zip"
	fi
	echo "Downloading AWS CLI v2 for linux/$arch" >&2
	curl -fsSL "https://awscli.amazonaws.com/$zip" \
		-o "$tmp/awscliv2.zip"
	unzip -q "$tmp/awscliv2.zip" -d "$tmp"

	set -- --install-dir "$install_dir" --bin-dir "$bin_dir"
	if [ -d "$install_dir" ]; then
		set -- "$@" --update
	fi
	"$tmp/aws/install" "$@"
	"$bin_dir/aws" --version
	;;
Darwin)
	[ "$(id -u)" -eq 0 ] || fail "macOS installation requires root privileges"
	if [ -n "$version" ]; then
		pkg="AWSCLIV2-$version.pkg"
	else
		pkg="AWSCLIV2.pkg"
	fi
	echo "Downloading AWS CLI v2 for macOS" >&2
	curl -fsSL "https://awscli.amazonaws.com/$pkg" -o "$tmp/AWSCLIV2.pkg"
	installer -pkg "$tmp/AWSCLIV2.pkg" -target /
	/usr/local/bin/aws --version
	;;
*)
	fail "unsupported operating system: $(uname -s)"
	;;
esac
