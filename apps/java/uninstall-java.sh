#!/bin/sh
set -eu

case "${APP_VERSION:-}" in
26.0.2_10 | 25.0.4_7 | 21.0.12_8 | 17.0.20_8 | 11.0.32_9 | 8u502-b07) ;;
*)
	echo "java uninstall: unsupported APP_VERSION: ${APP_VERSION:-<empty>}" >&2
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
