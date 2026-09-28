#!/bin/sh
set -eu

# Installs one Azure CLI version into a tree of its own.
#
# Microsoft publishes no self-contained Linux archive — the build pipeline
# produces an MSI, a Windows zip, Docker images, Homebrew, RPM, DEB and a Python
# wheel, and nothing else. Of the routes that work on any distribution, pip into
# a virtual environment is the one Microsoft supports (`az upgrade` knows it as
# the `PIP` installer); their curl-into-bash script reads from /dev/tty and so
# cannot run unattended, and the apt and dnf repositories would add a Microsoft
# package source to the node, which no app in this catalog does.
#
# One directory per version, not one shared directory: the runtime installs the
# new version before removing the old one, so a shared directory would have the
# superseded version's uninstall delete the install that just replaced it. `go`,
# `java`, `node` and `terraform` are version-scoped for the same reason.

fail() {
	echo "azure install: $*" >&2
	exit 1
}

note() {
	echo "azure install: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# python3 on its own is not enough: Debian and Ubuntu ship it without the piece
# that creates virtual environments, and Alpine without the piece that seeds
# pip. Same idea as gcloud's ensure_python and the ensure_unzip in aws,
# terraform and vault — try it, install through whichever package manager the
# node has, then check again.
#
# The probe builds a throwaway environment under the work directory. It must not
# touch the real one: on a re-install that would destroy a working CLI before a
# single byte had been fetched.
venv_works() {
	probe=$work/probe
	rm -rf "$probe"
	python3 -m venv "$probe" >/dev/null 2>&1
}

ensure_venv() {
	venv_works && return 0
	[ "$(id -u)" -eq 0 ] ||
		fail "python3 cannot create a virtual environment, and installing the package for it needs root"

	echo "azure install: installing the python3 virtual environment package" >&2
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q python3-pip
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q python3-pip
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive --quiet install python3-pip
	elif command -v apk >/dev/null 2>&1; then
		apk add --no-progress --quiet py3-pip
	else
		fail "python3 cannot create a virtual environment and no supported package manager was found"
	fi
	venv_works ||
		fail "python3 still cannot create a virtual environment after installing the package"
}

case "$(uname -s)" in
Linux) ;;
*) fail "supported on Linux only: $(uname -s)" ;;
esac
[ "$(id -u)" -eq 0 ] || fail "must run as root"

need python3
need curl

# Checked before anything is downloaded. Without this, pip on an older
# interpreter quietly resolves to the last release that still supported it —
# 2.66.2 on python3.8 — and the node ends up years behind with no complaint.
python3 -c 'import sys; raise SystemExit(sys.version_info[:2] < (3, 10))' ||
	fail "azure-cli needs python3 3.10 or newer; this node has $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"

root=${AZURE_CLI_INSTALL_DIR:-/opt/azure-cli}
bin_dir=${AZURE_CLI_BIN_DIR:-/usr/local/bin}
# An empty or root path would make the removals below catastrophic, and the
# README tells operators to set this variable by hand. gcloud guards the same way.
case "$root" in
'' | /) fail "AZURE_CLI_INSTALL_DIR must not be empty or /" ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; exit 1' HUP INT TERM

# APP_VERSION is unset when the request resolved to the implicit `default` tag,
# which is what the version list offers first. That is not an error: it means no
# particular version was asked for. The newest is then resolved here rather than
# left to pip, because the directory is named after the version and has to be
# known before the install, not after it.
version=${APP_VERSION:-}
if [ -n "$version" ]; then
	printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
		fail "invalid APP_VERSION: $version"
else
	note "no version was requested; taking the newest published"
	curl -fsSL https://pypi.org/pypi/azure-cli/json -o "$work/index.json" ||
		fail "no version was requested and the release index could not be read"
	# Matched anywhere in the token rather than only at its start: "version" is
	# not the first key of the object that holds it, so requiring position one
	# finds nothing when the document arrives without spaces.
	version=$(tr -d ' \t' <"$work/index.json" | tr ',' '\n' |
		awk 'match($0, /"version":"[^"]*"/) {
			line = substr($0, RSTART + 11, RLENGTH - 12)
			print line
			exit
		}')
	printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
		fail "the release index named no usable version: '$version'"
	note "newest published azure-cli is $version"
fi

prefix=$root/$version
venv=$prefix/venv
marker=$root/.orc-azure-install

marker_has() {
	[ -f "$marker" ] && grep -q "^$1=1\$" "$marker"
}

# Two facts, each written only once it becomes true, and never downgraded by a
# later install of another version into the same root.
write_marker() {
	kept=''
	if [ -f "$marker" ]; then
		kept=$(grep '^version=' "$marker" || true)
	fi
	if [ "$link_created" -eq 0 ] && [ -z "$kept" ]; then
		return 0
	fi
	{
		printf 'link-created=%s\n' "$link_created"
		[ -z "$kept" ] || printf '%s\n' "$kept"
	} >"$marker" || fail "could not write $marker"
}

link_created=0
if marker_has link-created; then
	link_created=1
fi

# Already installed and working: nothing to fetch, and nothing to destroy. Every
# CLI app in the catalog short-circuits this way — aws, gcloud and claude all do
# — and without it a same-version re-install removes the tree before the
# download, so a network blip leaves the node with no CLI.
if [ -x "$venv/bin/az" ]; then
	present=$("$venv/bin/pip" show azure-cli 2>/dev/null | sed -n 's/^Version: //p')
	if [ "$present" = "$version" ]; then
		note "azure-cli $version is already installed at $prefix"
		exit 0
	fi
fi

ensure_venv

note "installing azure-cli==$version — the CLI and its dependencies are a few hundred megabytes"
rm -rf "$prefix"
mkdir -p "$prefix"
# From here a failure leaves a half-built tree that start would find, so it is
# cleaned up. Only this version's tree: the others are not ours to touch.
trap 'rm -rf "$work" "$prefix"' EXIT
trap 'rm -rf "$work" "$prefix"; exit 1' HUP INT TERM

python3 -m venv "$venv" || fail "could not create the virtual environment at $venv"
"$venv/bin/pip" install --no-cache-dir --upgrade pip >/dev/null ||
	fail "could not update pip in $venv"
# pip verifies every wheel against the hash PyPI publishes for it, so the
# download is checked without this script fetching a checksum of its own.
"$venv/bin/pip" install --no-cache-dir "azure-cli==$version" ||
	fail "could not install azure-cli==$version"

az=$venv/bin/az
[ -x "$az" ] || fail "the wheel installed no az command in $venv/bin"

installed=$("$venv/bin/pip" show azure-cli 2>/dev/null | sed -n 's/^Version: //p')
[ "$installed" = "$version" ] ||
	fail "installed version '$installed' does not match $version"

# Telemetry is off for this one command: a check the package performs is no
# business of Microsoft's. It stays on for the node's own use, which is the
# node's decision — the README names the variable that turns it off. The output
# is kept, because a failure here is exactly when it is wanted.
if ! output=$(AZURE_CORE_COLLECT_TELEMETRY=false "$az" version 2>&1); then
	fail "azure-cli $installed does not run on this node: $output"
fi

# A real file, or a symlink pointing somewhere outside this app's root, is
# somebody else's doing — another Azure CLI, or a wrapper. Neither is claimed:
# the link is only recorded as ours when we created it or when it already
# belonged to us, so uninstall can never take away something it did not put there.
mkdir -p "$bin_dir"
link=$bin_dir/az
if [ -L "$link" ]; then
	previous=$(readlink "$link" 2>/dev/null || true)
	case "$previous" in
	"$root"/*) link_created=1 ;;
	*)
		# Not ours, so it stays — and the flag goes with it, or the link would
		# be overwritten two lines below by the very code this branch exists to
		# prevent.
		link_created=0
		note "warning: $link points at $previous and is left in place; this install is at $az"
		;;
	esac
elif [ -e "$link" ]; then
	fail "$link already exists and is not a symlink; remove it and install again"
else
	link_created=1
fi
if [ "$link_created" -eq 1 ]; then
	ln -sfn "$az" "$link" || fail "could not link $link"
fi

# Recorded so uninstall can find this version when the platform names none —
# the same `default` case that may have brought us here.
if [ ! -f "$marker" ] || ! grep -q "^version=$version\$" "$marker"; then
	write_marker
	printf 'version=%s\n' "$version" >>"$marker" ||
		fail "could not record $version in $marker"
else
	write_marker
fi

trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; exit 1' HUP INT TERM
note "azure-cli $installed installed at $prefix"
