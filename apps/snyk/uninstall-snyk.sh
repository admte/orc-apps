#!/bin/sh
set -eu

root=${SNYK_INSTALL_ROOT:-/opt/snyk}
bin_dir=${SNYK_BIN_DIR:-/usr/local/bin}
link="$bin_dir/snyk"

version=${APP_VERSION:-}
version=${version#v}

if [ -z "$version" ]; then
	# The install ran without a resolved version and took the then-current release, so
	# the tree the exposure symlink points at is the one to remove.
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$root"/*/snyk)
		version=${target#"$root"/}
		version=${version%/snyk}
		;;
	*)
		echo "snyk uninstall: no installed version to remove" >&2
		exit 0
		;;
	esac
fi

prefix="$root/$version"

# Ownership guard: drop the exposure symlink only while it still points into this
# version's own tree. The runtime installs the new version before running the superseded
# version's uninstall, so by this point the link may already belong to a newer install.
if [ -L "$link" ]; then
	case "$(readlink "$link")" in
	"$prefix"/*) rm -f "$link" ;;
	esac
fi

rm -rf "$prefix"
rmdir "$root" 2>/dev/null || true
