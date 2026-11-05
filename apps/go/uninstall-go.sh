#!/bin/sh
set -eu

root=${GO_INSTALL_ROOT:-/opt/go}
bin_dir=${GO_BIN_DIR:-/usr/local/bin}

version=${APP_VERSION:-}
version=${version#go}

if [ -z "$version" ]; then
	# The install ran without a resolved version and took the then-newest
	# release, so the tree the exposure symlink points at is the one to remove.
	target=$(readlink "$bin_dir/go" 2>/dev/null || true)
	case "$target" in
	"$root"/*/bin/go)
		version=${target#"$root"/}
		version=${version%/bin/go}
		;;
	*)
		echo "go uninstall: no installed version to remove" >&2
		exit 0
		;;
	esac
fi

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.)
	echo "go uninstall: invalid version: $version" >&2
	exit 1
	;;
esac

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
