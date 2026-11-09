#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: uninstall-checkov.sh [--version=VERSION] [--install-root=DIR] [--bin-dir=DIR]

Removes one Checkov release that install-checkov.sh installed, and the checkov link
while it still points into that release.

  --version=VERSION   Checkov release to remove, e.g. 3.4.0
                      (default: the release the checkov link points at)
  --install-root=DIR  directory each release is installed under (default: /opt/checkov)
  --bin-dir=DIR       where checkov is linked (default: /usr/local/bin)
  --help              show this help
USAGE
}

usage_error() {
	echo "checkov uninstall: $*" >&2
	usage >&2
	exit 2
}

version=
root=/opt/checkov
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--version=*) version=${arg#--version=} ;;
	--install-root=*) root=${arg#--install-root=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$root" ] || usage_error "--install-root must not be empty"
[ -n "$bin_dir" ] || usage_error "--bin-dir must not be empty"

link="$bin_dir/checkov"
version=${version#v}

if [ -z "$version" ]; then
	# The install ran without a version and took the then-current release, so the tree
	# the exposure symlink points at is the one to remove.
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$root"/*/checkov)
		version=${target#"$root"/}
		version=${version%/checkov}
		;;
	*)
		echo "checkov uninstall: no installed version to remove"
		exit 0
		;;
	esac
fi

case "$version" in
*[!0-9.]* | .* | *..* | *.)
	echo "checkov uninstall: invalid version: $version" >&2
	exit 1
	;;
esac

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
