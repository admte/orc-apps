#!/bin/sh
set -eu

prefix=${TERRAFORM_PREFIX:-/opt/terraform}
bin_dir=${TERRAFORM_BIN_DIR:-/usr/local/bin}
link="$bin_dir/terraform"

version=${APP_VERSION:-${TERRAFORM_VERSION:-}}
version=${version#v}

if [ -z "$version" ]; then
	# The install ran without a resolved version and picked the then-current
	# release, so the tree the exposure symlink points at is the one to remove.
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$prefix"/*/terraform)
		version=${target#"$prefix"/}
		version=${version%/terraform}
		;;
	*)
		echo "terraform uninstall: no installed version to remove" >&2
		exit 0
		;;
	esac
fi

install_dir="$prefix/$version"

# Ownership guard: drop the exposure symlink only while it still points into
# this version's own tree. A newer version installed alongside this one has
# already repointed the link and keeps it.
if [ -L "$link" ]; then
	case "$(readlink "$link")" in
	"$install_dir"/*) rm -f "$link" ;;
	esac
fi

rm -rf "$install_dir"
