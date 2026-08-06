#!/bin/sh
set -eu

fail() {
	echo "vault install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# Cloud images routinely ship without unzip, which the Vault release archive
# needs. Install it from the host package manager rather than failing, so a
# stock image works unattended.
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

case "$(uname -s)" in
Linux) os=linux ;;
Darwin) os=darwin ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

need curl
need mktemp
ensure_unzip

if [ -z "${APP_VERSION:-}" ] && [ -z "${VAULT_VERSION:-}" ] && command -v vault >/dev/null 2>&1; then
	vault version
	exit 0
fi

version=${APP_VERSION:-${VAULT_VERSION:-}}
if [ -z "$version" ]; then
	release=$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/vault/latest) ||
		fail "could not determine the latest Vault version"
	version=$(printf '%s' "$release" |
		sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	[ -n "$version" ] || fail "latest Vault version is missing from the release response"
fi
version=${version#v}

archive="vault_${version}_${os}_${arch}.zip"
base_url="https://releases.hashicorp.com/vault/$version"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

echo "Downloading Vault $version for $os/$arch" >&2
curl -fsSL "$base_url/$archive" -o "$tmp_dir/$archive"
curl -fsSL "$base_url/vault_${version}_SHA256SUMS" -o "$tmp_dir/SHA256SUMS"

expected=$(awk -v archive="$archive" '$2 == archive { print $1 }' "$tmp_dir/SHA256SUMS")
[ -n "$expected" ] || fail "checksum for $archive was not published"

if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$tmp_dir/$archive" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
	actual=$(shasum -a 256 "$tmp_dir/$archive" | awk '{ print $1 }')
else
	fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "checksum verification failed for $archive"

unzip -q "$tmp_dir/$archive" -d "$tmp_dir/unpacked"
[ -f "$tmp_dir/unpacked/vault" ] || fail "Vault binary is missing from $archive"

install_dir=${VAULT_INSTALL_DIR:-/usr/local/bin}
mkdir -p "$install_dir"
install -m 0755 "$tmp_dir/unpacked/vault" "$install_dir/vault"

"$install_dir/vault" version
