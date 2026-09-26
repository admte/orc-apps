#!/bin/sh
set -eu

# Removes what this app created, and only that: the shared browser cache.
#
# The system libraries stay. They are not ours — several were on the node before
# this app arrived, other software links against them, and `apt-get remove` on a
# list of eighty packages is a good way to break a machine. The catalog draws the
# same line: `go`, `node` and `java` remove their own trees, `docker` and
# `cpp-dev-tools` leave system packages alone.

note() {
	echo "playwright uninstall: $*" >&2
}

cache_dir=${PLAYWRIGHT_CACHE_DIR:-/usr/local/share/ms-playwright}

if [ -d "$cache_dir" ]; then
	rm -rf "$cache_dir" || {
		echo "playwright uninstall: could not remove $cache_dir" >&2
		exit 1
	}
	note "removed the shared browser cache $cache_dir"
else
	note "no shared browser cache to remove dir=$cache_dir"
fi

note "the system libraries are left in place; they are shared with the rest of the node"
