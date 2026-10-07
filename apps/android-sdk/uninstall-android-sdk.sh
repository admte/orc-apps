#!/bin/sh
set -eu

# Removes the SDK tree this app created. It is entirely ours — the command-line
# tools, the accepted licences, and whatever components builds added underneath —
# so it can go precisely, the same way `go` and `node` remove their own trees.
#
# The temporary JDK the install phase may have used was deleted when that phase
# ended; nothing else was put on the node.

note() {
	echo "android-sdk uninstall: $*" >&2
}

sdk_root=${ANDROID_SDK_INSTALL_ROOT:-/opt/android-sdk}

if [ -d "$sdk_root" ]; then
	rm -rf "$sdk_root" || {
		echo "android-sdk uninstall: could not remove $sdk_root" >&2
		exit 1
	}
	note "removed the SDK at $sdk_root"
else
	note "no SDK to remove dir=$sdk_root"
fi
