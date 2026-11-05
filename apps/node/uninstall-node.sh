#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: uninstall-node.sh --version=VERSION [--install-root=DIR] [--bin-dir=DIR]

Removes one Node.js release that install-node.sh installed, and the node, npm,
npx and corepack links that still point into it.

  --version=VERSION   Node.js release to remove, e.g. 20.17.0
  --install-root=DIR  directory each release is unpacked under (default: /opt/node)
  --bin-dir=DIR       where the commands are linked (default: /usr/local/bin)
  --help              show this help
USAGE
}

usage_error() {
	echo "node uninstall: $*" >&2
	usage >&2
	exit 2
}

requested=
root=/opt/node
bin_dir=/usr/local/bin
for arg; do
	case $arg in
	--version=*) requested=${arg#--version=} ;;
	--install-root=*) root=${arg#--install-root=} ;;
	--bin-dir=*) bin_dir=${arg#--bin-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$requested" ] || usage_error "--version is required"
[ -n "$root" ] || usage_error "--install-root must not be empty"
[ -n "$bin_dir" ] || usage_error "--bin-dir must not be empty"

version=${requested#v}
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.)
	echo "node uninstall: invalid version: $requested" >&2
	exit 1
	;;
esac
prefix="$root/$version"

for name in node npm npx corepack; do
	link="$bin_dir/$name"
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$prefix"/*) rm -f "$link" ;;
	esac
done

rm -rf "$prefix"
rmdir "$root" 2>/dev/null || true
