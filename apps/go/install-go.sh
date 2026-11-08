#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-go.sh [--version=VERSION] [--install-root=DIR] [--bin-dir=DIR]

Installs one Go release under its own directory and links go and gofmt onto
PATH. Without --version it installs the latest stable release.

  --version=VERSION   Go release to install, e.g. 1.22.5 (default: latest)
  --install-root=DIR  directory each release is unpacked under (default: /opt/go)
  --bin-dir=DIR       where go and gofmt are linked (default: /usr/local/bin)
  --help              show this help
USAGE
}

fail() {
	echo "go install: $*" >&2
	exit 1
}

usage_error() {
	echo "go install: $*" >&2
	usage >&2
	exit 2
}

requested=
root=/opt/go
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--version=*) requested=${arg#--version=} ;;
	--install-root=*) root=${arg#--install-root=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$root" ] || usage_error "--install-root must not be empty"
[ -n "$bin_dir" ] || usage_error "--bin-dir must not be empty"

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

if [ -z "$requested" ]; then
	requested=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n 1) ||
		fail "could not determine the latest Go release"
	[ -n "$requested" ] || fail "could not determine the latest Go release"
fi
version=${requested#go}
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $requested" ;;
esac
asset="go$version.linux-$arch.tar.gz"
base=https://go.dev/dl
prefix="$root/$version"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

curl -fsSL "$base/$asset" -o "$work/$asset"
curl -fsSL "$base/?mode=json&include=all" -o "$work/releases.json"
expected=$(awk -v asset="$asset" '
	/"filename"[[:space:]]*:/ {
		line = $0
		sub(/^.*"filename"[[:space:]]*:[[:space:]]*"/, "", line)
		sub(/".*$/, "", line)
		found = (line == asset)
	}
	found && /"sha256"[[:space:]]*:/ {
		line = $0
		sub(/^.*"sha256"[[:space:]]*:[[:space:]]*"/, "", line)
		sub(/".*$/, "", line)
		print line
		exit
	}
' "$work/releases.json")
[ -n "$expected" ] || fail "checksum for $asset was not published"
actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

rm -rf "$prefix"
mkdir -p "$prefix"
tar -xzf "$work/$asset" --strip-components=1 -C "$prefix"

mkdir -p "$bin_dir"
for name in go gofmt; do
	ln -sfn "$prefix/bin/$name" "$bin_dir/$name"
done

actual_version=$("$prefix/bin/go" version)
case "$actual_version" in
*" go$version "*) ;;
*) fail "installed version '$actual_version' does not match $version" ;;
esac
