#!/bin/sh
set -eu

fail() {
	echo "terraform install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# Cloud images routinely ship without unzip, which the Terraform release archive
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

version=${APP_VERSION:-${TERRAFORM_VERSION:-}}
if [ -z "$version" ]; then
	# No version was resolved (the app was installed as `terraform:default`), so
	# ask the vendor which release is current instead of guessing one.
	release=$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/terraform/latest) ||
		fail "could not determine the latest Terraform version"
	version=$(printf '%s' "$release" |
		sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	[ -n "$version" ] || fail "latest Terraform version is missing from the release response"
fi
version=${version#v}

prefix=${TERRAFORM_PREFIX:-/opt/terraform}
bin_dir=${TERRAFORM_BIN_DIR:-/usr/local/bin}
install_dir="$prefix/$version"
link="$bin_dir/terraform"

archive="terraform_${version}_${os}_${arch}.zip"
base_url="https://releases.hashicorp.com/terraform/$version"
tmp_dir=$(mktemp -d)
tmp_link="$bin_dir/.terraform.orc.$$"
trap 'rm -rf "$tmp_dir" "$tmp_link"' EXIT HUP INT TERM

echo "Downloading Terraform $version for $os/$arch" >&2
curl -fsSL "$base_url/$archive" -o "$tmp_dir/$archive"
curl -fsSL "$base_url/terraform_${version}_SHA256SUMS" -o "$tmp_dir/SHA256SUMS"

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
[ -f "$tmp_dir/unpacked/terraform" ] || fail "Terraform binary is missing from $archive"

# Claim only this version's own subtree: /opt/terraform may already exist from a
# manual install or from another version of this app.
mkdir -p "$install_dir"
install -m 0755 "$tmp_dir/unpacked/terraform" "$install_dir/terraform"

# Repoint the exposure symlink atomically, so a concurrent `terraform` call
# never sees a missing PATH entry while versions are switched.
mkdir -p "$bin_dir"
[ ! -d "$link" ] || fail "$link is a directory"
rm -f "$tmp_link"
ln -s "$install_dir/terraform" "$tmp_link"
mv -f "$tmp_link" "$link"

CHECKPOINT_DISABLE=1 "$install_dir/terraform" version
