#!/bin/sh
set -eu

# Removes one SDK band from the shared root, and nothing that was not ours.
#
# Only `sdk/<version>` goes: that directory is exactly what this app added.
# The shared runtimes beside it are deliberately left, because two SDK bands of
# the same release carry the same runtime — removing it would break the SDK that
# is still installed. Microsoft documents removing these versioned directories
# by hand and warns that their version numbers differ from the SDK's.
#
# The root, and the command in the path, go only if the install phase is the one
# that put them there. On a node that already had .NET, neither is ours.

fail() {
	echo "dotnet uninstall: $*" >&2
	exit 1
}

note() {
	echo "dotnet uninstall: $*" >&2
}

root=${DOTNET_INSTALL_ROOT:-/opt/dotnet}
bin_dir=${DOTNET_BIN_DIR:-/usr/local/bin}
marker=$root/.orc-dotnet-install

marker_has() {
	[ -f "$marker" ] && grep -q "^$1=1\$" "$marker"
}

# APP_VERSION is unset when the assignment resolved to the implicit `default`
# tag, exactly as it was at install. What install put here is recorded in the
# marker, so the answer is read rather than recomputed — a newer patch may have
# been published since, and that one was never installed.
version=${APP_VERSION:-}
if [ -z "$version" ]; then
	version=$(grep '^sdk=' "$marker" 2>/dev/null | tail -1 | cut -d= -f2 || true)
	[ -n "$version" ] ||
		fail "no version was requested and $marker records none; nothing to remove"
	note "no version was requested; removing $version, the last this app installed"
fi
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
	fail "invalid APP_VERSION: $version"

if [ -d "$root/sdk/$version" ]; then
	rm -rf "$root/sdk/$version" || fail "could not remove $root/sdk/$version"
	note "removed sdk/$version"
else
	note "no sdk/$version to remove under $root"
fi

# The record goes with the thing it recorded, so a later uninstall without a
# version does not point at something already gone.
if [ -f "$marker" ]; then
	kept=$(grep -v "^sdk=$version\$" "$marker" || true)
	if [ -n "$kept" ]; then
		printf '%s\n' "$kept" >"$marker" || fail "could not update $marker"
	fi
fi

# Only version directories count. `sdk/` also holds NuGetFallbackFolder on the
# older bands, and a failed install can leave something else there; counting
# those would keep a root that has no SDK left in it.
remaining=0
if [ -d "$root/sdk" ]; then
	for entry in "$root"/sdk/*; do
		[ -d "$entry" ] || continue
		case "${entry##*/}" in
		[0-9]*.[0-9]*.[0-9]*) remaining=$((remaining + 1)) ;;
		esac
	done
fi

if [ "$remaining" -gt 0 ]; then
	note "kept $root: $remaining other SDK version(s) still installed"
	exit 0
fi

# Written as an `if` and not `test && rm`, which under `set -e` would end the
# script the moment the test came out false.
if marker_has link-created; then
	link=$bin_dir/dotnet
	target=$(readlink "$link" 2>/dev/null || true)
	if [ "$target" = "$root/dotnet" ]; then
		rm -f "$link"
		note "removed $link"
	fi
fi

if marker_has root-created; then
	rm -rf "$root" || fail "could not remove $root"
	note "removed $root with the last SDK version"
else
	# The root stays, so the record of what we touched goes instead of lingering
	# inside someone else's installation.
	rm -f "$marker"
	note "kept $root: this node had .NET before the app was installed"
fi
