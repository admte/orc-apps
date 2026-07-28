#!/bin/sh
set -eu

fail() {
	echo "aws configure: $*" >&2
	exit 1
}

read_param() {
	value=$1
	file=$2
	if [ -n "$file" ]; then
		[ -r "$file" ] || fail "credential file is not readable"
		tr -d '\r\n' <"$file"
	else
		printf '%s' "$value"
	fi
}

if command -v aws >/dev/null 2>&1; then
	aws_bin=$(command -v aws)
elif [ -n "${AWS_CLI_BIN_DIR:-}" ] && [ -x "$AWS_CLI_BIN_DIR/aws" ]; then
	aws_bin=$AWS_CLI_BIN_DIR/aws
elif [ -x /usr/local/bin/aws ]; then
	aws_bin=/usr/local/bin/aws
else
	fail "AWS CLI is not installed"
fi
"$aws_bin" --version >/dev/null

access_key=$(read_param "${AWS_ACCESS_KEY_ID:-}" "${AWS_ACCESS_KEY_ID_FILE:-}")
secret_key=$(read_param "${AWS_SECRET_ACCESS_KEY:-}" "${AWS_SECRET_ACCESS_KEY_FILE:-}")

if { [ -n "$access_key" ] && [ -z "$secret_key" ]; } ||
	{ [ -z "$access_key" ] && [ -n "$secret_key" ]; }; then
	fail "aws_access_key_id and aws_secret_access_key must be provided together"
fi

if [ -z "$access_key" ]; then
	echo "AWS CLI is ready; credentials were not provided" >&2
	exit 0
fi

[ -n "${HOME:-}" ] || fail "HOME is required to configure AWS CLI"
credentials_file=${AWS_SHARED_CREDENTIALS_FILE:-"$HOME/.aws/credentials"}
credentials_dir=$(dirname "$credentials_file")
mkdir -p "$credentials_dir"
tmp=$(mktemp "$credentials_dir/.credentials.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
umask 077

{
	printf '%s\n' '[default]'
	printf 'aws_access_key_id = %s\n' "$access_key"
	printf 'aws_secret_access_key = %s\n' "$secret_key"
	if [ -f "$credentials_file" ]; then
		awk '
			/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
				skip = ($0 ~ /^[[:space:]]*\[default\][[:space:]]*$/)
			}
			!skip { print }
		' "$credentials_file"
	fi
} >"$tmp"
unset access_key secret_key

chmod 0600 "$tmp"
mv "$tmp" "$credentials_file"
trap - EXIT HUP INT TERM

echo "AWS CLI credentials configured" >&2
