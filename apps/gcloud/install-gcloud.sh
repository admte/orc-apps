#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-gcloud.sh [--force] [--install-dir=DIR] [--bin-dir=DIR]

Installs the latest Google Cloud CLI and links gcloud onto PATH. Leaves a gcloud
command that is already on PATH as it is.

  --force            install even when gcloud is already on PATH
  --install-dir=DIR  where the SDK is unpacked (default: /usr/local/google-cloud-sdk)
  --bin-dir=DIR      where gcloud is linked (default: /usr/local/bin)
  --help             show this help
USAGE
}

fail() {
	echo "gcloud install: $*" >&2
	exit 1
}

usage_error() {
	echo "gcloud install: $*" >&2
	usage >&2
	exit 2
}

force=
install_dir=/usr/local/google-cloud-sdk
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--force) force=1 ;;
	--install-dir=*) install_dir=${arg#--install-dir=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$bin_dir" ] || usage_error "--bin-dir must not be empty"

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

python_supported() {
	command -v python3 >/dev/null 2>&1 &&
		python3 -c 'import sys; raise SystemExit(not ((3, 10) <= sys.version_info[:2] <= (3, 14)))'
}

ensure_python() {
	python_supported && return 0
	if [ "$(uname -s)" != Linux ] || [ "$(id -u)" -ne 0 ]; then
		fail "Python 3.10-3.14 is required for this Google Cloud CLI archive"
	fi

	echo "Installing Python 3 for Google Cloud CLI" >&2
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get update -qq
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q python3
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q python3
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive --quiet install python3
	elif command -v apk >/dev/null 2>&1; then
		apk add --no-progress --quiet python3
	else
		fail "Python 3.10-3.14 is required and no supported package manager was found"
	fi
	python_supported || fail "installed Python version is not supported; need 3.10-3.14"
}

if command -v gcloud >/dev/null 2>&1 && [ -z "$force" ]; then
	gcloud version
	exit 0
fi

case "$(uname -s)" in
Linux)
	case "$(uname -m)" in
	x86_64 | amd64) platform=linux-x86_64 ;;
	aarch64 | arm64) platform=linux-arm ;;
	*) fail "unsupported architecture: $(uname -m)" ;;
	esac
	;;
Darwin)
	case "$(uname -m)" in
	x86_64 | amd64) platform=darwin-x86_64 ;;
	aarch64 | arm64) platform=darwin-arm ;;
	*) fail "unsupported architecture: $(uname -m)" ;;
	esac
	;;
*)
	fail "unsupported operating system: $(uname -s)"
	;;
esac

need curl
need tar
if [ "$platform" != linux-x86_64 ]; then
	ensure_python
fi
archive="google-cloud-cli-$platform.tar.gz"
url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$archive"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "Downloading Google Cloud CLI for $platform" >&2
curl -fsSL "$url" -o "$tmp/$archive"
tar -xzf "$tmp/$archive" -C "$tmp"
[ -x "$tmp/google-cloud-sdk/bin/gcloud" ] ||
	fail "gcloud executable is missing from $archive"

case "$install_dir" in
"" | /) fail "unsafe --install-dir: $install_dir" ;;
esac

mkdir -p "$(dirname "$install_dir")" "$bin_dir"
rm -rf "$install_dir"
mv "$tmp/google-cloud-sdk" "$install_dir"
ln -sf "$install_dir/bin/gcloud" "$bin_dir/gcloud"

CLOUDSDK_CORE_DISABLE_PROMPTS=1 "$bin_dir/gcloud" version
