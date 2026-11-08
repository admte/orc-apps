#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: uninstall-go.sh [--version=VERSION] [--install-root=DIR] [--bin-dir=DIR]

Removes one Go release that install-go.sh installed, and the go and gofmt links
that still point into it.

  --version=VERSION   Go release to remove, e.g. 1.22.5
                      (default: the release the go link points at)
  --install-root=DIR  directory each release is unpacked under (default: /opt/go)
  --bin-dir=DIR       where go and gofmt are linked (default: /usr/local/bin)
  --help              show this help
USAGE
}

usage_error() {
	echo "go uninstall: $*" >&2
	usage >&2
	exit 2
}

requested=
root=/opt/go
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
[ -n "$root" ] || usage_error "--install-root must not be empty"
[ -n "$bin_dir" ] || usage_error "--bin-dir must not be empty"

if [ -z "$requested" ]; then
	# The install took the newest release because the request resolved to the
	# implicit `default` tag, so remove the one the go link points at.
	target=$(readlink "$bin_dir/go" 2>/dev/null || true)
	case "$target" in
	"$root"/*/bin/go)
		requested=${target#"$root"/}
		requested=${requested%/bin/go}
		;;
	*)
		echo "go uninstall: no installed version to remove"
		exit 0
		;;
	esac
fi

version=${requested#go}
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.)
	echo "go uninstall: invalid version: $requested" >&2
	exit 1
	;;
esac
prefix="$root/$version"

for name in go gofmt; do
	link="$bin_dir/$name"
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$prefix"/*) rm -f "$link" ;;
	esac
done

rm -rf "$prefix"
rmdir "$root" 2>/dev/null || true
