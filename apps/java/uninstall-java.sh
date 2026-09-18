#!/bin/sh
set -eu

[ -n "${APP_VERSION:-}" ] || {
	echo "java uninstall: APP_VERSION is required" >&2
	exit 1
}

case "$APP_VERSION" in
'' | *[!0-9.]* | .* | *..* | *.)
	echo "java uninstall: invalid APP_VERSION: $APP_VERSION" >&2
	exit 1
	;;
esac

root=${JAVA_INSTALL_ROOT:-/opt/java}
bin_dir=${JAVA_BIN_DIR:-/usr/local/bin}
prefix="$root/$APP_VERSION"

if [ -d "$prefix/bin" ]; then
	for executable in "$prefix"/bin/*; do
		name=${executable##*/}
		link="$bin_dir/$name"
		target=$(readlink "$link" 2>/dev/null || true)
		case "$target" in
		"$prefix"/*) rm -f "$link" ;;
		esac
	done
fi

current_target=$(readlink "$root/current" 2>/dev/null || true)
[ "$current_target" != "$prefix" ] || rm -f "$root/current"
rm -rf "$prefix"
rmdir "$root" 2>/dev/null || true
