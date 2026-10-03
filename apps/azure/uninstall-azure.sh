#!/bin/sh
set -eu

# Removes one version's tree, and the command in the path only when it pointed
# at that version and this app is what put it there.
#
# `aws` and `gcloud` ship no uninstall at all, but they also predate the rule
# the versioned apps follow: an app that owns a directory of its own removes it,
# the way `go`, `java`, `node` and `terraform` do.
#
# The CLI's sign-in state is deliberately left alone. It lives in the home
# directory of whoever the start phase ran as, it may hold more than this app
# put there, and it is not ours to delete.

fail() {
	echo "azure uninstall: $*" >&2
	exit 1
}

note() {
	echo "azure uninstall: $*" >&2
}

root=${AZURE_CLI_INSTALL_DIR:-/opt/azure-cli}
bin_dir=${AZURE_CLI_BIN_DIR:-/usr/local/bin}
case "$root" in
'' | /) fail "AZURE_CLI_INSTALL_DIR must not be empty or /" ;;
esac

marker=$root/.orc-azure-install
link=$bin_dir/az

marker_has() {
	[ -f "$marker" ] && grep -q "^$1=1\$" "$marker"
}

# APP_VERSION is unset when the request resolved to the implicit `default` tag,
# exactly as it was at install. What install put here is recorded, so the answer
# is read rather than recomputed — a newer release may have appeared since, and
# that one was never installed.
version=${APP_VERSION:-}
if [ -z "$version" ]; then
	version=$(grep '^version=' "$marker" 2>/dev/null | tail -1 | cut -d= -f2 || true)
	[ -n "$version" ] ||
		fail "no version was requested and $marker records none; nothing to remove"
	note "no version was requested; removing $version, the last this app installed"
fi
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
	fail "invalid APP_VERSION: $version"

prefix=$root/$version

if [ -d "$prefix" ]; then
	rm -rf "$prefix" || fail "could not remove $prefix"
	note "removed $prefix"
else
	note "no install to remove at $prefix"
fi

# The record goes with the thing it recorded.
if [ -f "$marker" ]; then
	kept=$(grep -v "^version=$version\$" "$marker" || true)
	if [ -n "$kept" ]; then
		printf '%s\n' "$kept" >"$marker" || fail "could not update $marker"
	fi
fi

# What remains, newest first.
remaining=$(
	for entry in "$root"/*; do
		[ -d "$entry" ] || continue
		name=${entry##*/}
		case "$name" in
		[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$name" ;;
		esac
	done | sort -V
)

if marker_has link-created; then
	target=$(readlink "$link" 2>/dev/null || true)
	case "$target" in
	"$prefix"/*)
		newest=$(printf '%s' "$remaining" | tail -1)
		if [ -n "$newest" ]; then
			# Another version is still installed, so the command keeps working
			# and simply points at that one.
			ln -sfn "$root/$newest/venv/bin/az" "$link" ||
				fail "could not repoint $link"
			note "$link now points at $newest"
		else
			rm -f "$link"
			note "removed $link"
		fi
		;;
	esac
fi

if [ -z "$remaining" ]; then
	rm -f "$marker"
	rmdir "$root" 2>/dev/null || true
	note "no versions left at $root"
fi
