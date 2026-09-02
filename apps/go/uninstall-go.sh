#!/bin/sh
set -eu

[ -n "${APP_VERSION:-}" ] || {
	echo "go uninstall: APP_VERSION is required" >&2
	exit 1
}

version=${APP_VERSION#go}
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.)
	echo "go uninstall: invalid APP_VERSION: $APP_VERSION" >&2
	exit 1
	;;
esac
root=${GO_INSTALL_ROOT:-/opt/go}
bin_dir=${GO_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"

for name in go gofmt; do
	link="$bin_dir/$name"
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$prefix"/*) rm -f "$link" ;;
	esac
done

rm -rf "$prefix"
rmdir "$root" 2>/dev/null || true
