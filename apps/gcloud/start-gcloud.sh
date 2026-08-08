#!/bin/sh
set -eu

fail() {
	echo "gcloud configure: $*" >&2
	exit 1
}

if command -v gcloud >/dev/null 2>&1; then
	gcloud_bin=$(command -v gcloud)
elif [ -n "${GCLOUD_BIN_DIR:-}" ] && [ -x "$GCLOUD_BIN_DIR/gcloud" ]; then
	gcloud_bin=$GCLOUD_BIN_DIR/gcloud
elif [ -n "${GCLOUD_INSTALL_DIR:-}" ] && [ -x "$GCLOUD_INSTALL_DIR/bin/gcloud" ]; then
	gcloud_bin=$GCLOUD_INSTALL_DIR/bin/gcloud
elif [ -x /usr/local/bin/gcloud ]; then
	gcloud_bin=/usr/local/bin/gcloud
else
	fail "Google Cloud CLI is not installed"
fi

"$gcloud_bin" version >/dev/null

key_file=${SERVICE_ACCOUNT_KEY_FILE:-}
if [ -z "$key_file" ]; then
	echo "Google Cloud CLI is ready; service account key was not provided" >&2
	exit 0
fi
[ -r "$key_file" ] || fail "SERVICE_ACCOUNT_KEY_FILE is not readable"

echo "Activating Google Cloud service account" >&2
CLOUDSDK_CORE_DISABLE_PROMPTS=1 "$gcloud_bin" auth activate-service-account \
	--key-file="$key_file" \
	--quiet
echo "Google Cloud service account activation complete" >&2
