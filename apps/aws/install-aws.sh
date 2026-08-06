#!/bin/sh
set -eu

fail() {
	echo "aws install: $*" >&2
	exit 1
}

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

if command -v aws >/dev/null 2>&1 && [ -z "${APP_VERSION:-}" ] && [ -z "${AWS_CLI_FORCE_INSTALL:-}" ]; then
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

	if [ -n "${APP_VERSION:-}" ]; then
		zip="awscli-exe-linux-$arch-$APP_VERSION.zip"
	else
		zip="awscli-exe-linux-$arch.zip"
	fi
	echo "Downloading AWS CLI v2 for linux/$arch" >&2
	curl -fsSL "https://awscli.amazonaws.com/$zip" \
		-o "$tmp/awscliv2.zip"
	unzip -q "$tmp/awscliv2.zip" -d "$tmp"

	install_dir=${AWS_CLI_INSTALL_DIR:-/usr/local/aws-cli}
	bin_dir=${AWS_CLI_BIN_DIR:-/usr/local/bin}
	set -- --install-dir "$install_dir" --bin-dir "$bin_dir"
	if [ -d "$install_dir" ]; then
		set -- "$@" --update
	fi
	"$tmp/aws/install" "$@"
	"$bin_dir/aws" --version
	;;
Darwin)
	[ "$(id -u)" -eq 0 ] || fail "macOS installation requires root privileges"
	if [ -n "${APP_VERSION:-}" ]; then
		pkg="AWSCLIV2-$APP_VERSION.pkg"
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
