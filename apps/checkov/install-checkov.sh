#!/bin/sh
set -eu

# Installs one Checkov release into its own directory and exposes it through a symlink,
# the same shape trivy, syft, k6, cosign and snyk use.
#
# Two things differ from the rest of the catalog:
#
#   - The project publishes no checksums file. GitHub reports a SHA-256 of its own for
#     each release asset, and that is what is verified against. It guards a truncated or
#     tampered download, not a compromised release: it is GitHub's hash of the file it
#     holds, not a signature by the publisher.
#
#   - The archive stores the binary as "dist/checkov", and the Windows one as
#     "dist//checkov.exe" with a doubled separator. Nothing here relies on that layout:
#     the entry is taken by its file name.

fail() {
	echo "checkov install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

need curl
need mktemp

case "$(uname -s)" in
Linux) ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
x86_64 | amd64) asset=checkov_linux_X86_64.zip ;;
*) fail "unsupported architecture: $(uname -m); the project builds x86_64 only" ;;
esac

api=https://api.github.com/repos/bridgecrewio/checkov/releases

version=${APP_VERSION:-}
version=${version#v}
if [ -n "$version" ]; then
	case "$version" in
	*[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
	esac
fi

root=${CHECKOV_INSTALL_ROOT:-/opt/checkov}
bin_dir=${CHECKOV_BIN_DIR:-/usr/local/bin}
link="$bin_dir/checkov"
# Known already when a version was requested; filled in after discovery otherwise.
prefix=
[ -z "$version" ] || prefix="$root/$version"

work=$(mktemp -d)
tmp_link="$bin_dir/.checkov.orc.$$"
trap 'rm -rf "$work" "$tmp_link"' EXIT HUP INT TERM

# Repoints the exposure symlink atomically, so a concurrent `checkov` call never sees a
# missing PATH entry while versions are switched.
expose() {
	mkdir -p "$bin_dir"
	[ ! -d "$link" ] || fail "$link is a directory"
	rm -f "$tmp_link"
	ln -s "$prefix/checkov" "$tmp_link"
	mv -f "$tmp_link" "$link"
}

# Both spellings are tried rather than betting on one.
reported_version() {
	"$1" --version 2>/dev/null || "$1" version 2>/dev/null || return 1
}

# True when this version is already on disk and runs. The pool image is baked straight
# after this phase and every node is then rebuilt from it, which runs this phase again on
# a disk that already carries the binary.
already_installed() {
	[ -x "$prefix/checkov" ] || return 1
	reported=$(reported_version "$prefix/checkov") || return 1
	case "$reported" in
	*"$version"*) return 0 ;;
	esac
	return 1
}

# A requested version can be answered from the node's own disk without touching the
# network at all. That matters here more than elsewhere: this app's checksum lives in the
# GitHub API rather than in a published file, so every install that gets as far as the
# API spends one of the sixty unauthenticated requests an hour GitHub allows per address
# — and a pool can hold more nodes than that behind one address.
if [ -n "$version" ] && already_installed; then
	expose
	echo "checkov install: checkov $version is already installed" >&2
	exit 0
fi

if [ -n "$version" ]; then
	release=$(curl -fsSL "$api/tags/$version") ||
		fail "could not read release $version from GitHub"
else
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag.
	# The newest version has to be asked for before the disk can be checked, because
	# until then there is no version to look for.
	echo "checkov install: no version was requested; taking the newest release" >&2
	release=$(curl -fsSL "$api/latest") ||
		fail "could not read the newest release from GitHub"
fi

# Whitespace is stripped first: the API pretty-prints, so the field separators carry
# spaces and newlines that would otherwise have to be matched.
flat=$(printf '%s' "$release" | tr -d ' \t\n\r')

if [ -z "$version" ]; then
	version=$(printf '%s' "$flat" | sed -n 's/.*"tag_name":"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
	[ -n "$version" ] || fail "the release response names no version"
	echo "checkov install: newest release is $version" >&2
	prefix="$root/$version"
	if already_installed; then
		expose
		echo "checkov install: checkov $version is already installed" >&2
		exit 0
	fi
fi

# The digest that follows this asset's name in the release document belongs to it: the
# fields are ordered within each asset object.
expected=$(printf '%s' "$flat" | awk -v needle="\"name\":\"$asset\"" '
	{
		i = index($0, needle)
		if (i == 0) exit
		rest = substr($0, i)
		j = index(rest, "\"digest\":\"sha256:")
		if (j == 0) exit
		print substr(rest, j + 17, 64)
	}')
case "$expected" in
*[!0-9a-f]* | '') fail "GitHub published no SHA-256 for $asset in release $version" ;;
esac
[ "${#expected}" -eq 64 ] || fail "GitHub published a malformed SHA-256 for $asset"

base="https://github.com/bridgecrewio/checkov/releases/download/$version"

echo "checkov install: downloading $asset" >&2
curl -fsSL "$base/$asset" -o "$work/$asset" || fail "could not download $asset"

if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
	actual=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
else
	fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

# Flattened on purpose: the archive's own path is "dist/checkov", and the Windows archive
# spells it with a doubled separator, so neither is trusted.
mkdir -p "$work/extract"
if command -v unzip >/dev/null 2>&1; then
	unzip -q -j "$work/$asset" -d "$work/extract" || fail "could not unpack $asset"
elif command -v python3 >/dev/null 2>&1; then
	python3 -I -c '
import os, shutil, sys, zipfile

source, destination = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(source) as archive:
    for entry in archive.infolist():
        name = os.path.basename(entry.filename.replace("\\", "/"))
        if not name:
            continue
        with archive.open(entry) as src, open(os.path.join(destination, name), "wb") as dst:
            shutil.copyfileobj(src, dst)
' "$work/$asset" "$work/extract" || fail "could not unpack $asset"
else
	fail "unzip or python3 is required to unpack $asset"
fi

[ -f "$work/extract/checkov" ] || fail "the archive holds no file named checkov"

# Claim only this version's own subtree: /opt/checkov may already hold other versions.
mkdir -p "$prefix"
install -m 0755 "$work/extract/checkov" "$prefix/checkov"

expose

reported=$(reported_version "$prefix/checkov") || fail "checkov does not run on this node"
case "$reported" in
*"$version"*) ;;
*) fail "installed version '$reported' does not match $version" ;;
esac

echo "checkov install: checkov $version installed at $prefix" >&2
