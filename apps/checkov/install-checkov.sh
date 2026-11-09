#!/bin/sh
set -eu

# Installs one Checkov release into its own directory and exposes it through a symlink,
# the same shape trivy, syft, k6, cosign and snyk use.
#
# Three things differ from the rest of the catalog:
#
#   - The project publishes no checksums file. GitHub reports a SHA-256 of its own for
#     each release asset, and that is what is verified against. It guards a truncated or
#     tampered download, not a compromised release: it is GitHub's hash of the file it
#     holds, not a signature by the publisher.
#
#   - The archive stores the binary as "dist/checkov", and the Windows one as
#     "dist//checkov.exe" with a doubled separator. Nothing here relies on that layout:
#     the entry is taken by its file name.
#
#   - The release binary is a PyInstaller bundle whose libpython is linked against a
#     glibc newer than several supported images carry. Those images get the same release
#     built by pip into a virtual environment instead; see install_with_pip below.

usage() {
	cat <<'USAGE'
Usage: install-checkov.sh [--version=VERSION] [--install-root=DIR] [--bin-dir=DIR]

Installs one Checkov release under its own directory and links checkov onto PATH.

  --version=VERSION   Checkov release to install, e.g. 3.4.0
                      (default: the newest release the project publishes)
  --install-root=DIR  directory each release is installed under (default: /opt/checkov)
  --bin-dir=DIR       where checkov is linked (default: /usr/local/bin)
  --help              show this help
USAGE
}

fail() {
	echo "checkov install: $*" >&2
	exit 1
}

usage_error() {
	echo "checkov install: $*" >&2
	usage >&2
	exit 2
}

# Progress on stdout: the node log renders an install's stderr as warnings.
note() {
	echo "checkov install: $*"
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

version=
root=/opt/checkov
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

need curl
need mktemp

case "$(uname -s)" in
Linux) ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
x86_64 | amd64) asset=checkov_linux_X86_64.zip ;;
*) fail "unsupported architecture: $(uname -m); the project builds x86_64 only" ;;
esac

api=https://api.github.com/repos/bridgecrewio/checkov/releases

version=${version#v}
if [ -n "$version" ]; then
	case "$version" in
	*[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
	esac
fi

link="$bin_dir/checkov"
# Known already when a version was requested; filled in after discovery otherwise.
prefix=
[ -z "$version" ] || prefix="$root/$version"

work=$(mktemp -d)
tmp_link="$bin_dir/.checkov.orc.$$"
trap 'rm -rf "$work" "$tmp_link"' EXIT HUP INT TERM

# Repoints the exposure symlink atomically, so a concurrent `checkov` call never sees a
# missing PATH entry while versions are switched.
expose() {
	mkdir -p "$bin_dir"
	[ ! -d "$link" ] || fail "$link is a directory"
	rm -f "$tmp_link"
	ln -s "$prefix/checkov" "$tmp_link"
	mv -f "$tmp_link" "$link"
}

# Both spellings are tried rather than betting on one. Whatever the binary writes is
# kept, stderr included: when a PyInstaller bundle cannot start, the loader's message is
# the only account of why, and discarding it leaves nothing but "does not run".
reported_version() {
	"$1" --version 2>&1 || "$1" version 2>&1 || return 1
}

# True when this version is already on disk and runs. The pool image is baked straight
# after this phase and every node is then rebuilt from it, which runs this phase again on
# a disk that already carries the binary.
already_installed() {
	[ -x "$prefix/checkov" ] || return 1
	reported=$(reported_version "$prefix/checkov") || return 1
	case "$reported" in
	*"$version"*) return 0 ;;
	esac
	return 1
}

# The 3.4.0 bundle ships a libpython3.9 linked against glibc 2.38, so it cannot start on
# an older image: Debian 12 carries 2.36 and AlmaLinux 9 carries 2.34. The binary exits
# without running and the bake fails. Kept here in one place, because which glibc the
# bundle needs is the project's choice and can move between releases.
required_glibc=2.38

glibc_release() {
	libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || libc=
	case "$libc" in
	'glibc '*)
		echo "${libc#glibc }"
		return 0
		;;
	esac
	ldd --version 2>/dev/null | head -1 |
		sed -n 's/.*[^0-9.]\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# False when glibc is older than the bundle needs, and also when there is no glibc to
# report at all: a musl image cannot run the bundle either.
glibc_is_new_enough() {
	libc=$(glibc_release)
	[ -n "$libc" ] || return 1
	have_major=${libc%%.*}
	have_minor=${libc#*.}
	have_minor=${have_minor%%.*}
	want_major=${required_glibc%%.*}
	want_minor=${required_glibc#*.}
	case "$have_major.$have_minor" in
	*[!0-9.]* | '') return 1 ;;
	esac
	if [ "$have_major" -ne "$want_major" ]; then
		[ "$have_major" -gt "$want_major" ]
		return
	fi
	[ "$have_minor" -ge "$want_minor" ]
}

# Debian and Ubuntu ship the venv module as its own package, and a minimal image does not
# carry it. A failure here is not fatal: the venv attempt that follows reports it.
ensure_venv_module() {
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update -qq &&
			DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
				apt-get install -y -qq python3-venv || true
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q python3-pip || true
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q python3-pip || true
	fi
}

# Builds the same release with pip, into a virtual environment of its own under this
# version's directory, and points $prefix/checkov at it. Nothing downstream cares which
# of the two paths produced that file.
install_with_pip() {
	python=
	for candidate in python3 python3.13 python3.12 python3.11 python3.10 python3.9; do
		if command -v "$candidate" >/dev/null 2>&1; then
			python=$(command -v "$candidate")
			break
		fi
	done
	[ -n "$python" ] || fail "the release binary needs glibc $required_glibc, which this node does not have, and python3 is not installed to build checkov $version instead"

	note "glibc $(glibc_release) is older than $required_glibc, so the release binary cannot start here; building checkov $version with pip instead"
	rm -rf "$prefix"
	mkdir -p "$prefix"
	# The first attempt is a probe, and both its streams are dropped: when the venv
	# module is missing, python explains the lack on stdout at some length, which would
	# otherwise reach the node log and read as a failure rather than a step on the way.
	if ! "$python" -m venv "$prefix/venv" >/dev/null 2>&1; then
		ensure_venv_module
		"$python" -m venv "$prefix/venv" ||
			fail "could not create a virtual environment with $python"
	fi
	"$prefix/venv/bin/python" -m pip install --quiet --no-cache-dir --upgrade pip ||
		fail "could not update pip inside the virtual environment"
	"$prefix/venv/bin/python" -m pip install --quiet --no-cache-dir "checkov==$version" ||
		fail "pip could not install checkov $version"
	[ -x "$prefix/venv/bin/checkov" ] ||
		fail "pip installed checkov $version without a checkov command"
	ln -sfn "$prefix/venv/bin/checkov" "$prefix/checkov"
}

# Downloads the release binary, verifies it against GitHub's digest and puts it in place.
install_release_binary() {
	# The digest that follows this asset's name in the release document belongs to it: the
	# fields are ordered within each asset object.
	expected=$(printf '%s' "$flat" | awk -v needle="\"name\":\"$asset\"" '
		{
			i = index($0, needle)
			if (i == 0) exit
			rest = substr($0, i)
			j = index(rest, "\"digest\":\"sha256:")
			if (j == 0) exit
			print substr(rest, j + 17, 64)
		}')
	case "$expected" in
	*[!0-9a-f]* | '') fail "GitHub published no SHA-256 for $asset in release $version" ;;
	esac
	[ "${#expected}" -eq 64 ] || fail "GitHub published a malformed SHA-256 for $asset"

	base="https://github.com/bridgecrewio/checkov/releases/download/$version"

	note "downloading $asset"
	curl -fsSL "$base/$asset" -o "$work/$asset" || fail "could not download $asset"

	if command -v sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
	elif command -v shasum >/dev/null 2>&1; then
		actual=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
	else
		fail "sha256sum or shasum is required"
	fi
	[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

	# Flattened on purpose: the archive's own path is "dist/checkov", and the Windows
	# archive spells it with a doubled separator, so neither is trusted.
	mkdir -p "$work/extract"
	if command -v unzip >/dev/null 2>&1; then
		unzip -q -j "$work/$asset" -d "$work/extract" || fail "could not unpack $asset"
	elif command -v python3 >/dev/null 2>&1; then
		python3 -I -c '
import os, shutil, sys, zipfile

source, destination = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(source) as archive:
    for entry in archive.infolist():
        name = os.path.basename(entry.filename.replace("\\", "/"))
        if not name:
            continue
        with archive.open(entry) as src, open(os.path.join(destination, name), "wb") as dst:
            shutil.copyfileobj(src, dst)
' "$work/$asset" "$work/extract" || fail "could not unpack $asset"
	else
		fail "unzip or python3 is required to unpack $asset"
	fi

	[ -f "$work/extract/checkov" ] || fail "the archive holds no file named checkov"

	# Claim only this version's own subtree: /opt/checkov may already hold other versions.
	rm -rf "$prefix"
	mkdir -p "$prefix"
	install -m 0755 "$work/extract/checkov" "$prefix/checkov"
}

# A requested version can be answered from the node's own disk without touching the
# network at all. That matters here more than elsewhere: this app's checksum lives in the
# GitHub API rather than in a published file, so every install that gets as far as the
# API spends one of the sixty unauthenticated requests an hour GitHub allows per address
# — and a pool can hold more nodes than that behind one address.
if [ -n "$version" ] && already_installed; then
	expose
	note "checkov $version is already installed"
	exit 0
fi

if [ -n "$version" ]; then
	release=$(curl -fsSL "$api/tags/$version") ||
		fail "could not read release $version from GitHub"
else
	# No version was requested, so the request resolved to the implicit `default` tag.
	# The newest version has to be asked for before the disk can be checked, because
	# until then there is no version to look for.
	note "no version was requested; taking the newest release"
	release=$(curl -fsSL "$api/latest") ||
		fail "could not read the newest release from GitHub"
fi

# Whitespace is stripped first: the API pretty-prints, so the field separators carry
# spaces and newlines that would otherwise have to be matched.
flat=$(printf '%s' "$release" | tr -d ' \t\n\r')

if [ -z "$version" ]; then
	version=$(printf '%s' "$flat" | sed -n 's/.*"tag_name":"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
	[ -n "$version" ] || fail "the release response names no version"
	note "newest release is $version"
	prefix="$root/$version"
	if already_installed; then
		expose
		note "checkov $version is already installed"
		exit 0
	fi
fi

if glibc_is_new_enough; then
	install_release_binary
else
	install_with_pip
fi

expose

if ! reported=$(reported_version "$prefix/checkov"); then
	# Whatever it said on the way out is the only account of why it would not start.
	[ -z "$reported" ] || printf '%s\n' "$reported" >&2
	fail "checkov $version does not run on this node"
fi
case "$reported" in
*"$version"*) ;;
*) fail "installed version '$reported' does not match $version" ;;
esac

note "checkov $version installed at $prefix"
