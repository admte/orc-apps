#!/bin/sh
set -eu

# Removes one version's tree. It does NOT touch /var/lib/forgejo: that path is declared
# under `persist`, and the contract is explicit that an uninstall must not delete a
# declared persisted path. Removing it here would destroy every repository on the node
# the moment a version was switched.

root=${FORGEJO_INSTALL_ROOT:-/opt/forgejo}
bin_dir=${FORGEJO_BIN_DIR:-/usr/local/bin}
link="$bin_dir/forgejo"

version=${APP_VERSION:-}
version=${version#v}

if [ -z "$version" ]; then
	# The install ran without a resolved version and took the then-current release, so
	# the tree the exposure symlink points at is the one to remove.
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$root"/*/forgejo)
		version=${target#"$root"/}
		version=${version%/forgejo}
		;;
	*)
		echo "forgejo uninstall: no installed version to remove" >&2
		exit 0
		;;
	esac
fi

prefix="$root/$version"

# Ownership guard: drop the exposure symlink only while it still points into this
# version's own tree. The runtime installs the new version before running the superseded
# version's uninstall, so by this point the link may already belong to a newer install —
# and the service resolves its binary through that link on every restart.
if [ -L "$link" ]; then
	case "$(readlink "$link")" in
	"$prefix"/*) rm -f "$link" ;;
	esac
fi

rm -rf "$prefix"
rmdir "$root" 2>/dev/null || true

# The service account stays. It owns the persisted data directory, so removing it would
# leave those files orphaned on a volume the platform keeps.
