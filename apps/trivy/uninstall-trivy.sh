#!/bin/sh
set -eu

root=${TRIVY_INSTALL_ROOT:-/opt/trivy}
bin_dir=${TRIVY_BIN_DIR:-/usr/local/bin}
link="$bin_dir/trivy"

version=${APP_VERSION:-}
version=${version#v}

if [ -z "$version" ]; then
	# The install ran without a resolved version and took the then-current release, so
	# the tree the exposure symlink points at is the one to remove. terraform resolves
	# its own uninstall the same way.
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$root"/*/trivy)
		version=${target#"$root"/}
		version=${version%/trivy}
		;;
	*)
		echo "trivy uninstall: no installed version to remove" >&2
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
