#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: start-gcloud.sh [--service-account-key-file=PATH] [--install-dir=DIR]
                       [--bin-dir=DIR]

Checks that the Google Cloud CLI runs and, given a service account key file,
activates that service account.

  --service-account-key-file=PATH  file holding a service account JSON key
  --install-dir=DIR                where install unpacked the SDK
                                   (default: /usr/local/google-cloud-sdk)
  --bin-dir=DIR                    where install linked gcloud (default: /usr/local/bin)
  --help                           show this help
USAGE
}

fail() {
	echo "gcloud configure: $*" >&2
	exit 1
}

usage_error() {
	echo "gcloud configure: $*" >&2
	usage >&2
	exit 2
}

key_file=
install_dir=/usr/local/google-cloud-sdk
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--service-account-key-file=*) key_file=${arg#--service-account-key-file=} ;;
	--install-dir=*) install_dir=${arg#--install-dir=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

if command -v gcloud >/dev/null 2>&1; then
	gcloud_bin=$(command -v gcloud)
elif [ -x "$bin_dir/gcloud" ]; then
	gcloud_bin=$bin_dir/gcloud
elif [ -x "$install_dir/bin/gcloud" ]; then
	gcloud_bin=$install_dir/bin/gcloud
else
	fail "Google Cloud CLI is not installed"
fi

"$gcloud_bin" version >/dev/null

if [ -z "$key_file" ]; then
	echo "Google Cloud CLI is ready; service account key was not provided" >&2
	exit 0
fi
[ -r "$key_file" ] || fail "the service account key file is not readable"

echo "Activating Google Cloud service account" >&2
CLOUDSDK_CORE_DISABLE_PROMPTS=1 "$gcloud_bin" auth activate-service-account \
	--key-file="$key_file" \
	--quiet
echo "Google Cloud service account activation complete" >&2
