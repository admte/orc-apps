#!/bin/sh
set -eu

# Installs one .NET SDK version into a root shared by every installed version.
#
# This departs from `go`, `java` and `node`, which give each version its own
# tree. .NET is built the other way round: the archive is already laid out by
# version inside — sdk/<v>, shared/*/<v>, host/fxr/<v> — and Microsoft documents
# that "different versions of .NET can be extracted to the same folder, which
# coexist side-by-side". Separate roots would be mutually invisible islands: the
# muxer resolves everything next to itself, so `dotnet --list-sdks` would show
# one version and a project whose global.json pins another would fail to build.

fail() {
	echo "dotnet install: $*" >&2
	exit 1
}

note() {
	echo "dotnet install: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# .NET refuses to start on Linux without ICU. Reached only when the SDK has
# already failed to run *and* said so about globalization, so an unrelated
# failure does not get the node's packages rearranged underneath it.
ensure_icu() {
	[ "$(id -u)" -eq 0 ] ||
		fail "the .NET SDK needs ICU and installing it needs root"

	echo "dotnet install: installing ICU, which the SDK needs to run" >&2
	if command -v apt-get >/dev/null 2>&1; then
		# Not fatal on its own: a node with a stale mirror may still have the
		# package cached, and the install below is what decides.
		DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
		# On Debian and Ubuntu the runtime package carries the soname in its
		# name and the number differs per release, so it is looked up.
		package=$(apt-cache --names-only search '^libicu[0-9][0-9]*$' 2>/dev/null |
			awk '{ print $1 }' | sort -V | tail -1)
		[ -n "$package" ] || package=libicu-dev
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package"
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q libicu
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q libicu
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive --quiet install libicu
	elif command -v apk >/dev/null 2>&1; then
		# Alpine needs the data as well as the library; the .NET prerequisites
		# page names both.
		apk add --no-progress --quiet icu-libs icu-data-full
	else
		fail "the .NET SDK needs ICU and no supported package manager was found"
	fi
}

# The marker records what this app changed, so uninstall can put back exactly
# that and nothing else. Two facts, each written only when it becomes true, and
# never downgraded by a later install of a second version into the same root.
marker_has() {
	[ -f "$marker" ] && grep -q "^$1=1\$" "$marker"
}

write_marker() {
	# The `sdk=` lines are this app's record of what it installed, kept across a
	# rewrite of the flags above them.
	kept=''
	if [ -f "$marker" ]; then
		kept=$(grep '^sdk=' "$marker" || true)
	fi
	if [ "$root_created" -eq 0 ] && [ "$link_created" -eq 0 ] && [ -z "$kept" ]; then
		return 0
	fi
	{
		printf 'root-created=%s\n' "$root_created"
		printf 'link-created=%s\n' "$link_created"
		[ -z "$kept" ] || printf '%s\n' "$kept"
	} >"$marker" || fail "could not write $marker"
}

case "$(uname -s)" in
Linux) ;;
*) fail "supported on Linux only: $(uname -s)" ;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch=x64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac
[ "$(id -u)" -eq 0 ] || fail "must run as root"

need curl
need tar
need sha512sum

# APP_VERSION is unset when the assignment resolved to the implicit `default`
# tag — which is the entry the version list offers first, so it is the ordinary
# case and not an error. The newest offered SDK is then resolved below, from the
# same index the list itself is built from.
version=${APP_VERSION:-}
if [ -n "$version" ]; then
	printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
		fail "invalid APP_VERSION: $version"
fi

# Microsoft publishes a separate build for musl libc, and the glibc archive will
# not run on Alpine at all. This is the test their own dotnet-install.sh uses.
if (ldd --version 2>&1 || true) | grep -qi musl; then
	rid="linux-musl-$arch"
else
	rid="linux-$arch"
fi

feed=${DOTNET_FEED:-https://builds.dotnet.microsoft.com/dotnet}
metadata=${DOTNET_METADATA:-$feed/release-metadata}
root=${DOTNET_INSTALL_ROOT:-/opt/dotnet}
bin_dir=${DOTNET_BIN_DIR:-/usr/local/bin}
marker=$root/.orc-dotnet-install

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; exit 1' HUP INT TERM

# Which band publishes this version is asked, not guessed. Deriving it from the
# number is wrong for at least one band: 2.1.202 is published under 2.0. The
# index is the same document the version list is built from, so the answer is
# consistent with what the operator was offered — and when no version was
# requested at all, it is where the newest one comes from.
if [ -n "$version" ]; then
	note "resolving the release band for $version"
else
	note "no version was requested; taking the newest offered"
fi
if curl -fsSL "$metadata/releases-index.json" -o "$work/index.json"; then
	# The leading braces are stripped so a key that opens an object — which
	# "channel-version" always does — starts its token the same way any other
	# key does, whether the document arrives pretty-printed or minified.
	channel=$(tr -d ' \t' <"$work/index.json" | tr ',' '\n' | sed 's/^[][{}]*//' |
		awk -v want="\"$version\"" '
			index($0, "\"channel-version\":\"") == 1 {
				line = $0
				sub(/^"channel-version":"/, "", line)
				sub(/".*$/, "", line)
				seen = line
				next
			}
			index($0, "\"latest-sdk\":") == 1 && index($0, want) {
				print seen
				exit
			}
		')
else
	channel=''
fi

if [ -z "$version" ]; then
	# Every band's newest SDK, narrowed the same way artifact.yaml narrows the
	# offered list — plain three-part versions, .NET 5 and later — and the
	# highest of those wins. Both fields come from one line, so the band is
	# settled with the version and never has to be derived.
	[ -s "$work/index.json" ] ||
		fail "no version was requested and the release index could not be read"
	pair=$(tr -d ' \t' <"$work/index.json" | tr ',' '\n' | sed 's/^[][{}]*//' |
		awk '
			index($0, "\"channel-version\":\"") == 1 {
				line = $0
				sub(/^"channel-version":"/, "", line)
				sub(/".*$/, "", line)
				seen = line
				next
			}
			index($0, "\"latest-sdk\":\"") == 1 {
				line = $0
				sub(/^"latest-sdk":"/, "", line)
				sub(/".*$/, "", line)
				if (line ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {
					split(line, part, ".")
					if (part[1] + 0 >= 5) {
						print seen "\t" line
					}
				}
			}
		' | sort -t "$(printf '\t')" -k2,2V | tail -1)
	[ -n "$pair" ] || fail "the release index offers no installable SDK version"
	channel=${pair%%	*}
	version=${pair##*	}
	note "newest offered SDK is $version, from band $channel"
fi

# A version installed by hand need not be any band's newest, and then the index
# cannot name it. Falling back to the version's own prefix covers that.
[ -n "$channel" ] || channel=$(printf '%s' "$version" | cut -d. -f1,2)

asset="dotnet-sdk-$version-$rid.tar.gz"

note "reading the release metadata for band $channel"
curl -fsSL "$metadata/$channel/releases.json" -o "$work/releases.json" ||
	fail "could not read the release metadata for band $channel"

# The published SHA-512 for exactly this archive. The file is read as a stream of
# tokens rather than by line, so it does not matter whether Microsoft serves it
# pretty-printed or minified; `hash` is the key that follows `url` in each entry.
# `found` is cleared at the start of every entry, so an entry that somehow
# carried no hash could not lend the next entry's to this one.
expected=$(tr -d ' \t' <"$work/releases.json" | tr ',' '\n' | sed 's/^[][{}]*//' |
	awk -v asset="/$asset\"" '
		index($0, "\"name\":\"") == 1 { found = 0 }
		index($0, "\"url\":\"") == 1 && index($0, asset) { found = 1; next }
		found && index($0, "\"hash\":\"") == 1 {
			line = $0
			sub(/^"hash":"/, "", line)
			sub(/".*$/, "", line)
			print line
			exit
		}
	')
[ -n "$expected" ] ||
	fail "band $channel publishes no $asset — the version may not exist for this platform"
printf '%s' "$expected" | grep -Eq '^[0-9a-f]{128}$' ||
	fail "the published checksum for $asset is not a SHA-512: $expected"

note "downloading $asset"
curl -fsSL "$feed/Sdk/$version/$asset" -o "$work/$asset" ||
	fail "could not download $asset"

actual=$(sha512sum "$work/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

# Ownership is decided and recorded before anything can go wrong, so an install
# that fails halfway is still removable. A second version installed later must
# not downgrade what an earlier one recorded.
root_created=0
link_created=0
if marker_has root-created; then
	root_created=1
fi
if marker_has link-created; then
	link_created=1
fi
[ -d "$root" ] || root_created=1

mkdir -p "$root"
write_marker

# Straight into the shared root, with no staging directory: merging with what is
# already there is the point, so there is nothing to move into place afterwards.
# The archive has no wrapping directory of its own.
note "unpacking into $root"
tar -xzf "$work/$asset" -C "$root" || fail "could not unpack $asset into $root"

[ -x "$root/dotnet" ] || fail "$asset left no dotnet executable in $root"
[ -d "$root/sdk/$version" ] || fail "$asset left no sdk/$version in $root"

# The host resolves its own path with realpath before looking for anything
# beside it — its source says so in as many words — so a symlink here points the
# whole installation at the real root. The file may not be renamed, only linked.
mkdir -p "$bin_dir"
link=$bin_dir/dotnet
if [ -L "$link" ]; then
	# A link is ours to repoint — that is how a node moves between versions —
	# but say what it used to be, because uninstall can only remove ours, not
	# put back what was there.
	previous=$(readlink "$link" 2>/dev/null || true)
	if [ -n "$previous" ] && [ "$previous" != "$root/dotnet" ]; then
		note "warning: $link pointed at $previous and now points at this install"
	fi
	link_created=1
elif [ -e "$link" ]; then
	# A real file is somebody's deliberate doing — a wrapper, or another .NET.
	# Overwriting it would destroy something this app cannot put back.
	fail "$link already exists and is not a symlink; remove it and install again"
else
	link_created=1
fi
ln -sfn "$root/dotnet" "$link" || fail "could not link $link"
write_marker

# The install is only good if the SDK actually runs, and on a node without ICU it
# does not. Rather than guess whether the library is there, run it and see.
#
# Telemetry is off for this one command: a check the package performs is no
# business of Microsoft's. It stays on for the node's own builds, which is the
# node's decision to make — the README says which variable turns it off.
run_dotnet() {
	DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$root/dotnet" --list-sdks 2>&1
}

if ! output=$(run_dotnet); then
	# Only a globalization failure is ICU's, and only that one earns a package
	# install. Anything else is reported as it happened.
	case "$output" in
	*ICU* | *icu* | *globalization* | *Globalization*)
		note "the SDK reports missing globalization support"
		ensure_icu
		output=$(run_dotnet) ||
			fail "the SDK does not run on this node even with ICU installed: $output"
		;;
	*)
		fail "the SDK does not run on this node: $output"
		;;
	esac
fi

printf '%s\n' "$output" | grep -q "^$version " ||
	fail "sdk $version is not in the installed list: $output"

# Recorded so uninstall can find it when the platform names no version either —
# the same `default` case that brought us here.
if [ ! -f "$marker" ] || ! grep -q "^sdk=$version\$" "$marker"; then
	printf 'sdk=%s\n' "$version" >>"$marker" || fail "could not record $version in $marker"
fi

installed=$(printf '%s\n' "$output" | awk '{ print $1 }' | tr '\n' ' ')
note "dotnet $version installed at $root; SDKs now present: $installed"
