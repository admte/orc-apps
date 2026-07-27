#!/bin/sh
set -eu

fail() {
	echo "vault configure: $*" >&2
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

if [ -n "${VAULT_INSTALL_DIR:-}" ] && [ -x "$VAULT_INSTALL_DIR/vault" ]; then
	vault_bin=$VAULT_INSTALL_DIR/vault
elif command -v vault >/dev/null 2>&1; then
	vault_bin=$(command -v vault)
elif [ -x /usr/local/bin/vault ]; then
	vault_bin=/usr/local/bin/vault
else
	fail "vault CLI is not installed"
fi

role_id=$(read_param "${VAULT_ROLE_ID:-}" "${VAULT_ROLE_ID_FILE:-}")
secret_id=$(read_param "${VAULT_SECRET_ID:-}" "${VAULT_SECRET_ID_FILE:-}")

if [ -z "$role_id" ] && [ -n "$secret_id" ]; then
	fail "vault_role_id is required when vault_secret_id is provided"
fi

if [ -z "$role_id" ]; then
	echo "Vault CLI is ready; AppRole credentials were not provided" >&2
	exit 0
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
umask 077
printf '%s' "$role_id" >"$tmp_dir/role-id"
set -- "$vault_bin" write -field=token auth/approle/login role_id=@"$tmp_dir/role-id"
if [ -n "$secret_id" ]; then
	printf '%s' "$secret_id" >"$tmp_dir/secret-id"
	set -- "$@" secret_id=@"$tmp_dir/secret-id"
fi
unset role_id secret_id

echo "Authenticating Vault CLI with AppRole" >&2
token=$("$@") || fail "AppRole authentication failed"
[ -n "$token" ] || fail "AppRole authentication returned an empty token"

printf '%s' "$token" | "$vault_bin" login -no-print - >/dev/null ||
	fail "could not store the Vault token"
unset token

echo "Vault CLI AppRole authentication complete" >&2
