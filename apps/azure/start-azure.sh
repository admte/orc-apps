#!/bin/sh
set -eu

# Signs the Azure CLI in as a service principal, if one was given. Without
# credentials the CLI is simply left ready and unauthenticated — the same
# behaviour aws and gcloud have when their optional parameters are empty.

fail() {
	echo "azure configure: $*" >&2
	exit 1
}

note() {
	echo "azure configure: $*" >&2
}

# A parameter arrives either as a value or, when it is marked sensitive, as a
# file the platform wrote with 0600. Taken from aws/start-aws.sh, which solves
# the same problem the same way.
read_param() {
	value=$1
	file=$2
	if [ -n "$file" ]; then
		[ -r "$file" ] || fail "credential file is not readable: $file"
		tr -d '\r\n' <"$file"
	else
		printf '%s' "$value"
	fi
}

# This app's own install comes first. Install declines to take over an `az` that
# somebody else put on the PATH, so looking at the PATH first would sign that
# other CLI in instead of ours. vault/start-vault-unix.sh orders it the same way.
root=${AZURE_CLI_INSTALL_DIR:-/opt/azure-cli}
az_bin=''
if [ -n "${APP_VERSION:-}" ] && [ -x "$root/$APP_VERSION/venv/bin/az" ]; then
	az_bin=$root/$APP_VERSION/venv/bin/az
else
	# No version named, so take the newest this app installed.
	for entry in "$root"/*; do
		[ -x "$entry/venv/bin/az" ] || continue
		case "${entry##*/}" in
		[0-9]*.[0-9]*.[0-9]*) az_bin=$entry/venv/bin/az ;;
		esac
	done
fi
if [ -z "$az_bin" ]; then
	if [ -n "${AZURE_CLI_BIN_DIR:-}" ] && [ -x "$AZURE_CLI_BIN_DIR/az" ]; then
		az_bin=$AZURE_CLI_BIN_DIR/az
	elif command -v az >/dev/null 2>&1; then
		az_bin=$(command -v az)
	else
		fail "Azure CLI is not installed"
	fi
fi

# Every sibling verifies the binary right after finding it — aws, gcloud, jfrog
# and claude all do. Without it a broken install reports success here.
if ! probe=$(AZURE_CORE_COLLECT_TELEMETRY=false "$az_bin" version 2>&1); then
	fail "the Azure CLI at $az_bin does not run: $probe"
fi

client_id=$(read_param "${AZURE_CLIENT_ID:-}" "${AZURE_CLIENT_ID_FILE:-}")
client_secret=$(read_param "${AZURE_CLIENT_SECRET:-}" "${AZURE_CLIENT_SECRET_FILE:-}")
tenant_id=$(read_param "${AZURE_TENANT_ID:-}" "${AZURE_TENANT_ID_FILE:-}")

given=0
[ -z "${AZURE_CLIENT_ID:-}${AZURE_CLIENT_ID_FILE:-}" ] || given=1
[ -z "${AZURE_CLIENT_SECRET:-}${AZURE_CLIENT_SECRET_FILE:-}" ] || given=1
[ -z "${AZURE_TENANT_ID:-}${AZURE_TENANT_ID_FILE:-}" ] || given=1

if [ "$given" -eq 0 ]; then
	note "Azure CLI is ready; credentials were not provided"
	exit 0
fi
# One of the three was filled in, so the other two are wanted too — and naming
# the one that is missing beats "provide them together", which leaves the
# operator to work out which of three fields it means.
[ -n "$client_id" ] || fail "azure_client_id is required once any of the three credentials is given"
[ -n "$client_secret" ] || fail "azure_client_secret is required once any of the three credentials is given"
[ -n "$tenant_id" ] || fail "azure_tenant_id is required once any of the three credentials is given"

# azure-cli rewrites any argument whose first character is '@' into the contents
# of the file it names — before the arguments are parsed, for every option. An
# identifier starting with '@' would therefore send a file's contents to
# Microsoft as a client ID, and the rejection carries them into this log. Both
# identifiers are checked against the only characters they can legitimately hold.
case "$client_id" in
*[!0-9A-Za-z-]* | '') fail "azure_client_id is not a valid identifier" ;;
esac
case "$tenant_id" in
*[!0-9A-Za-z.-]* | '') fail "azure_tenant_id is not a valid identifier or domain" ;;
esac

# The CLI keeps its sign-in state here, and it writes the service principal's
# secret into it. Left where the CLI expects it, but created 0700 first: the CLI
# makes the directory with the default mask and writes its profile world
# readable, and the secret has no business being visible to the node's jobs.
config_dir=${AZURE_CONFIG_DIR:-}
if [ -z "$config_dir" ]; then
	[ -n "${HOME:-}" ] || fail "HOME is required to sign the Azure CLI in"
	config_dir=$HOME/.azure
fi
# Set before the directory is made, so there is no window at 0755 and so the
# files the CLI writes inside it are not world readable either. jfrog and vault
# do the same before writing their credentials.
umask 077
mkdir -p "$config_dir" || fail "could not create $config_dir"
AZURE_CONFIG_DIR=$config_dir
export AZURE_CONFIG_DIR

note "signing in as service principal $client_id"

# `--password @-` makes the CLI read the secret from standard input: the `@`
# prefix is expanded by azure-cli-core before the arguments are parsed, and `-`
# means stdin. The secret therefore never appears in the command line of any
# process, and /proc/<pid>/cmdline is world readable to every job on this node.
#
# Output goes to /dev/null because a successful sign-in prints the subscription
# list; failures still reach the log through stderr.
# The output is captured rather than discarded, so a refusal from Microsoft says
# why. It is safe to log: the secret arrived on standard input and azure-cli
# replaces every option value with a placeholder in its own logs, and its
# sign-in errors name the application, never the credential.
if ! out=$(printf '%s' "$client_secret" |
	AZURE_CORE_COLLECT_TELEMETRY=false "$az_bin" login \
		--service-principal \
		--username "$client_id" \
		--password @- \
		--tenant "$tenant_id" 2>&1); then
	fail "could not sign in as $client_id — check the secret and the tenant: $out"
fi

unset client_secret

note "Azure CLI signed in"
