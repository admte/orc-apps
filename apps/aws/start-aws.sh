#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: start-aws.sh [--access-key-id-file=PATH] [--secret-access-key-file=PATH]
                    [--bin-dir=DIR]

Checks that the AWS CLI runs and, given both key files, writes them to the
default profile of the shared credentials file.

  --access-key-id-file=PATH      file holding the AWS access key ID
  --secret-access-key-file=PATH  file holding the AWS secret access key
  --bin-dir=DIR                  where install linked the aws command
                                 (default: /usr/local/bin)
  --help                         show this help
USAGE
}

fail() {
	echo "aws configure: $*" >&2
	exit 1
}

usage_error() {
	echo "aws configure: $*" >&2
	usage >&2
	exit 2
}

access_key_file=
secret_key_file=
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--access-key-id-file=*) access_key_file=${arg#--access-key-id-file=} ;;
	--secret-access-key-file=*) secret_key_file=${arg#--secret-access-key-file=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

read_file() {
	if [ -n "$1" ]; then
		[ -r "$1" ] || fail "credential file is not readable"
		tr -d '\r\n' <"$1"
	fi
}

if command -v aws >/dev/null 2>&1; then
	aws_bin=$(command -v aws)
elif [ -x "$bin_dir/aws" ]; then
	aws_bin=$bin_dir/aws
else
	fail "AWS CLI is not installed"
fi
"$aws_bin" --version >/dev/null

access_key=$(read_file "$access_key_file")
secret_key=$(read_file "$secret_key_file")

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
