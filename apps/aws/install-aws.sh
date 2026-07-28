#!/bin/sh
set -eu

fail() {
	echo "aws install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

if command -v aws >/dev/null 2>&1 && [ -z "${AWS_CLI_FORCE_INSTALL:-}" ]; then
	aws --version
	exit 0
fi

need curl
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

case "$(uname -s)" in
Linux)
	need unzip
	case "$(uname -m)" in
	x86_64 | amd64) arch=x86_64 ;;
	aarch64 | arm64) arch=aarch64 ;;
	*) fail "unsupported architecture: $(uname -m)" ;;
	esac

	echo "Downloading AWS CLI v2 for linux/$arch" >&2
	curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$arch.zip" \
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
	echo "Downloading AWS CLI v2 for macOS" >&2
	curl -fsSL https://awscli.amazonaws.com/AWSCLIV2.pkg -o "$tmp/AWSCLIV2.pkg"
	installer -pkg "$tmp/AWSCLIV2.pkg" -target /
	/usr/local/bin/aws --version
	;;
*)
	fail "unsupported operating system: $(uname -s)"
	;;
esac
