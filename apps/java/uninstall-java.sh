#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: uninstall-java.sh [--version=VERSION] [--install-root=DIR] [--bin-dir=DIR]

Removes one JDK release that install-java.sh installed, and the command links
that still point into it. Without --version it removes the current release.

  --version=VERSION   JDK release to remove, e.g. 21.0.4
  --install-root=DIR  directory each release is unpacked under (default: /opt/java)
  --bin-dir=DIR       where the JDK commands are linked (default: /usr/local/bin)
  --help              show this help
USAGE
}

usage_error() {
	echo "java uninstall: $*" >&2
	usage >&2
	exit 2
}

version=
root=/opt/java
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

if [ -z "$version" ]; then
	# The install ran without --version and took the then-newest release, so
	# the current release is the one to remove.
	target=$(readlink "$root/current" 2>/dev/null || true)
	case "$target" in
	"$root"/*)
		version=${target#"$root"/}
		;;
	*)
		echo "java uninstall: no installed release to remove" >&2
		exit 0
		;;
	esac
fi

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.)
	echo "java uninstall: invalid version: $version" >&2
	exit 1
	;;
esac

prefix="$root/$version"

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
