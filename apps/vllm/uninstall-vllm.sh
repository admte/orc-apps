#!/bin/sh
set -eu

# Removes one version's tree. The weights cache is shared by every installed
# version, so it goes only when the last of them does — the same line `go`,
# `node` and `java` draw around their own trees, with the cache on our side of it.
#
# The service account is left in place: another installed version may still be
# running as it, and a stray system account costs nothing.

note() {
	echo "vllm uninstall: $*" >&2
}

fail() {
	echo "vllm uninstall: $*" >&2
	exit 1
}

[ -n "${APP_VERSION:-}" ] || fail "APP_VERSION is required"
printf '%s' "$APP_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
	fail "invalid APP_VERSION: $APP_VERSION"

root=${VLLM_INSTALL_ROOT:-/opt/vllm}
prefix="$root/$APP_VERSION"

if [ -d "$prefix" ]; then
	rm -rf "$prefix" || fail "could not remove $prefix"
	note "removed $prefix"
else
	note "no install to remove dir=$prefix"
fi

# Only when it pointed at the version being removed: another version may own it.
if [ -L "$root/current" ] && [ "$(readlink "$root/current")" = "$prefix" ]; then
	rm -f "$root/current"
fi

# Is any other version still installed? Everything under the root except the
# shared cache and the symlink is one.
remaining=0
for entry in "$root"/*; do
	[ -d "$entry" ] || continue
	case "${entry##*/}" in
	cache | current) continue ;;
	esac
	remaining=$((remaining + 1))
done

# The removed version may have been the one `current` named. Point it at the
# newest of what is left, so a start by hand keeps working.
if [ "$remaining" -gt 0 ] && [ ! -L "$root/current" ]; then
	newest=$(for entry in "$root"/*; do
		[ -d "$entry" ] || continue
		name=${entry##*/}
		case "$name" in
		cache | current) continue ;;
		esac
		printf '%s\n' "$name"
	done | sort -V | tail -1)
	if [ -n "$newest" ]; then
		ln -sfn "$root/$newest" "$root/current" || true
		note "current now points at $newest"
	fi
fi

if [ "$remaining" -eq 0 ]; then
	if [ -d "$root/cache" ]; then
		rm -rf "$root/cache" || fail "could not remove $root/cache"
		note "removed the weights cache with the last installed version"
	fi
	rm -f "$root/current"
	rmdir "$root" 2>/dev/null || true
else
	note "kept the weights cache: $remaining other version(s) still installed"
fi
