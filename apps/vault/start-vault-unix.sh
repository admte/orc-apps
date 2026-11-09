#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: start-vault-unix.sh [--addr=URL] [--role-id-file=PATH]
                           [--secret-id-file=PATH] [--install-dir=DIR]

Checks that the Vault CLI is installed and, given an AppRole role ID, signs it
in with AppRole and stores the token for the vault command.

  --addr=URL             Vault server URL, set as VAULT_ADDR for the vault CLI
  --role-id-file=PATH    file holding the AppRole role ID
  --secret-id-file=PATH  file holding the AppRole secret ID, for roles that
                         require one; needs --role-id-file
  --install-dir=DIR      where install put the vault command; when given it is
                         looked in before PATH (default: /usr/local/bin, looked
                         in after PATH)
  --help                 show this help
USAGE
}

fail() {
	echo "vault configure: $*" >&2
	exit 1
}

usage_error() {
	echo "vault configure: $*" >&2
	usage >&2
	exit 2
}

addr=
role_id_file=
secret_id_file=
install_dir=/usr/local/bin
install_dir_given=
for arg; do
	case $arg in
	--addr=*) addr=${arg#--addr=} ;;
	--role-id-file=*) role_id_file=${arg#--role-id-file=} ;;
	--secret-id-file=*) secret_id_file=${arg#--secret-id-file=} ;;
	--install-dir=*) install_dir=${arg#--install-dir=}; install_dir_given=1 ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$install_dir" ] || usage_error "--install-dir must not be empty"

# The vault CLI reads the server address from VAULT_ADDR.
if [ -n "$addr" ]; then
	VAULT_ADDR=$addr
	export VAULT_ADDR
fi

read_file() {
	if [ -n "$1" ]; then
		[ -r "$1" ] || fail "credential file is not readable"
		tr -d '\r\n' <"$1"
	fi
}

if [ -n "$install_dir_given" ] && [ -x "$install_dir/vault" ]; then
	vault_bin=$install_dir/vault
elif command -v vault >/dev/null 2>&1; then
	vault_bin=$(command -v vault)
elif [ -x "$install_dir/vault" ]; then
	vault_bin=$install_dir/vault
else
	fail "vault CLI is not installed"
fi

role_id=$(read_file "$role_id_file")
secret_id=$(read_file "$secret_id_file")

if [ -z "$role_id" ] && [ -n "$secret_id" ]; then
	fail "--role-id-file is required when --secret-id-file is given"
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
