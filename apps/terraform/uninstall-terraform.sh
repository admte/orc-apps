#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: uninstall-terraform.sh [--version=VERSION] [--prefix=DIR] [--bin-dir=DIR]

Removes one Terraform release that install-terraform.sh installed, and the
terraform link while it still points into it. Without --version it removes the
release the terraform link points at.

  --version=VERSION  Terraform release to remove, e.g. 1.9.5
  --prefix=DIR       directory each release is installed under (default: /opt/terraform)
  --bin-dir=DIR      where the terraform link is made (default: /usr/local/bin)
  --help             show this help
USAGE
}

usage_error() {
	echo "terraform uninstall: $*" >&2
	usage >&2
	exit 2
}

version=
prefix=/opt/terraform
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--version=*) version=${arg#--version=} ;;
	--prefix=*) prefix=${arg#--prefix=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$prefix" ] || usage_error "--prefix must not be empty"
[ -n "$bin_dir" ] || usage_error "--bin-dir must not be empty"

link="$bin_dir/terraform"
version=${version#v}

if [ -z "$version" ]; then
	# The install ran without --version and picked the then-current
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
