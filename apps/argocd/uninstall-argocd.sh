#!/bin/sh
set -eu

root=${ARGOCD_INSTALL_ROOT:-/opt/argocd}
bin_dir=${ARGOCD_BIN_DIR:-/usr/local/bin}
link="$bin_dir/argocd"

version=${APP_VERSION:-}
version=${version#v}

if [ -z "$version" ]; then
	# The install ran without a resolved version and took the then-current release, so
	# the tree the exposure symlink points at is the one to remove.
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$root"/*/argocd)
		version=${target#"$root"/}
		version=${version%/argocd}
		;;
	*)
		echo "argocd uninstall: no installed version to remove"
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
