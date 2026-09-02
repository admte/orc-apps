#!/bin/sh
set -eu

[ -n "${APP_VERSION:-}" ] || {
	echo "node uninstall: APP_VERSION is required" >&2
	exit 1
}

version=${APP_VERSION#v}
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.)
	echo "node uninstall: invalid APP_VERSION: $APP_VERSION" >&2
	exit 1
	;;
esac
root=${NODE_INSTALL_ROOT:-/opt/node}
bin_dir=${NODE_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"

for name in node npm npx corepack; do
	link="$bin_dir/$name"
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$prefix"/*) rm -f "$link" ;;
	esac
done

rm -rf "$prefix"
rmdir "$root" 2>/dev/null || true
