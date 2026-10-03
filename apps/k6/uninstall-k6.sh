#!/bin/sh
set -eu

root=${K6_INSTALL_ROOT:-/opt/k6}
bin_dir=${K6_BIN_DIR:-/usr/local/bin}
link="$bin_dir/k6"

version=${APP_VERSION:-}
version=${version#v}

if [ -z "$version" ]; then
	# The install ran without a resolved version and took the then-current release, so
	# the tree the exposure symlink points at is the one to remove.
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$root"/*/k6)
		version=${target#"$root"/}
		version=${version%/k6}
		;;
	*)
		echo "k6 uninstall: no installed version to remove" >&2
		exit 0
		;;
	esac
fi

prefix="$root/$version"

# Ownership guard: drop the exposure symlink only while it still points into this
# version's own tree. A newer version installed alongside this one has already repointed
# the link and keeps it.
if [ -L "$link" ]; then
	case "$(readlink "$link")" in
	"$prefix"/*) rm -f "$link" ;;
	esac
fi

rm -rf "$prefix"
rmdir "$root" 2>/dev/null || true
