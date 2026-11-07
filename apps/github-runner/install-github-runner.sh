#!/bin/sh
set -eu

# Downloads and unpacks the runner, and nothing else. It takes no url and no
# token: the build is the latest public release, whichever credential the runner
# later registers with, and the runner updates itself from there.

usage() {
	cat <<'USAGE'
Usage: install-github-runner.sh --os=OS --arch=ARCH [--service-user=NAME]

Downloads the latest GitHub Actions runner release into ./github-runner and hands
it to the service account. Registers nothing. Run as root.

  --os=OS              linux or darwin
  --arch=ARCH          amd64 or arm64
  --service-user=NAME  account the runner runs as, created if missing (default: ghrunner)
  --help               show this help
USAGE
}

fail() {
	echo "github-runner install: $*" >&2
	exit 1
}

usage_error() {
	echo "github-runner install: $*" >&2
	usage >&2
	exit 2
}

target_os=
target_arch=
service_user=ghrunner
for arg; do
	case $arg in
	--os=*) target_os=${arg#--os=} ;;
	--arch=*) target_arch=${arg#--arch=} ;;
	--service-user=*) service_user=${arg#--service-user=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

# Progress goes to stdout and only warnings and errors to stderr, so a healthy
# install writes nothing there.
note() {
	echo "github-runner install: $*"
}

warn() {
	echo "github-runner install: warning: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# Installs one package with the machine's package manager.
install_package() {
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get update -qq
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$1"
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q "$1"
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q "$1"
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive --quiet install "$1"
	else
		fail "$1 is required and no supported package manager was found"
	fi
}

# Installs a tool the image left out: minimal EL 9 and 10 cloud images ship
# without tar.
ensure_tool() {
	command -v "$1" >/dev/null 2>&1 && return 0
	note "installing $1"
	install_package "$1"
	need "$1"
}

has_libicu() {
	ldconfig -p | grep -q 'libicuuc\.so'
}

# The Actions runner refuses to configure or run as root ("Must not run with
# sudo"), but these scripts run as root. Create a dedicated service account
# here so start-github-runner.sh can drop to it.
ensure_service_user() {
	if id "$service_user" >/dev/null 2>&1; then
		return 0
	fi
	need useradd
	useradd -r -U -M -s /usr/sbin/nologin "$service_user"
	id "$service_user" >/dev/null 2>&1 || fail "failed to create service user $service_user"
}

# Selects this target's archive from GitHub's public release metadata for the
# runner: prints "download_url filename sha256". The checksum is the asset's own
# digest, else the one the release notes carry between BEGIN/END SHA markers, else
# empty.
select_release_asset() {
	python3 -c '
import json, re, sys
target_os, target_arch = sys.argv[1], sys.argv[2]
release = json.load(sys.stdin)
version = release.get("tag_name", "").lstrip("v")
ext = "zip" if target_os == "win" else "tar.gz"
name = "actions-runner-%s-%s-%s.%s" % (target_os, target_arch, version, ext)
for asset in release.get("assets", []):
    if asset.get("name") != name:
        continue
    checksum = ""
    digest = asset.get("digest") or ""
    if digest.startswith("sha256:"):
        checksum = digest[len("sha256:"):]
    else:
        marker = re.search(
            r"<!-- BEGIN SHA %s-%s -->\s*([0-9a-fA-F]{64})\s*<!-- END SHA" % (re.escape(target_os), re.escape(target_arch)),
            release.get("body") or "")
        if marker:
            checksum = marker.group(1)
    print(asset.get("browser_download_url", ""))
    print(name)
    print(checksum.lower())
    break
' "$1" "$2"
}

# The names GitHub's runner archives use for this target.
case $target_os in
linux) runner_os=linux ;;
darwin) runner_os=osx ;;
'') usage_error "--os is required" ;;
*) fail "unsupported OS $target_os" ;;
esac
case $target_arch in
amd64) runner_arch=x64 ;;
arm64) runner_arch=arm64 ;;
'') usage_error "--arch is required" ;;
*) fail "unsupported architecture $target_arch" ;;
esac
[ -n "$service_user" ] || usage_error "--service-user must not be empty"

[ "$(id -u)" -eq 0 ] || fail "must run as root"

need curl
need python3
# Not used here, but start-github-runner.sh drops to the service account with
# it, so a machine without it fails now rather than at the first start.
need setpriv
ensure_tool tar

work_dir=github-runner

ensure_service_user

mkdir -p "$work_dir"
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)

# The runner self-updates afterward, so no version pinning. GitHub's public
# release metadata needs no credential, which is why install takes none.
release_json=$(curl -fsSL \
	-H "Accept: application/vnd.github+json" \
	"https://api.github.com/repos/actions/runner/releases/latest") ||
	fail "failed to read the latest runner release"
selected=$(printf '%s' "$release_json" | select_release_asset "$runner_os" "$runner_arch")
url=$(printf '%s\n' "$selected" | sed -n 1p)
archive=$(printf '%s\n' "$selected" | sed -n 2p)
checksum=$(printf '%s\n' "$selected" | sed -n 3p)
[ -n "$url" ] && [ -n "$archive" ] ||
	fail "no runner download for $runner_os/$runner_arch"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

note "downloading the runner archive=$archive"
curl -fsSL "$url" -o "$tmp/$archive"
if [ -n "$checksum" ]; then
	need sha256sum
	actual=$(sha256sum "$tmp/$archive" | awk '{ print $1 }')
	[ "$actual" = "$checksum" ] ||
		fail "checksum mismatch archive=$archive expected=$checksum actual=$actual"
	note "checksum verified archive=$archive"
else
	warn "no published checksum; skipping verification archive=$archive"
fi
tar -xzf "$tmp/$archive" -C "$work_dir"

# The runner is a .NET program that exits at first start without libicu and the
# other libraries .NET needs, and Debian 13 and EL images ship without libicu.
# The runner carries its own installer for them, which knows each distribution's
# package names.
# The installer is all or nothing, though, so it may fail over a package the
# runner can do without; what decides is whether the libraries are there after.
if [ "$runner_os" = linux ]; then
	note "installing the runner's dependencies"
	DEBIAN_FRONTEND=noninteractive "$work_dir/bin/installdependencies.sh" ||
		warn "the runner's dependency installer failed; checking its libraries"
	# The trace provider's lttng is optional, and .NET opens ICU and OpenSSL at
	# run time, so ldd cannot see those two.
	missing=$(for lib in "$work_dir"/bin/*.so; do
		[ "${lib##*/}" = libcoreclrtraceptprovider.so ] || ldd "$lib" 2>/dev/null
	done | awk '/not found/ { print $1 }' | sort -u | tr '\n' ' ')
	[ -z "$missing" ] || fail "the runner's libraries are missing: $missing"
	# On EL 10 the installer asks for lttng-ust, which lives in the CRB
	# repository, and where CRB is disabled its single transaction installs
	# nothing, libicu included. libicu itself is in BaseOS, so it is installed on
	# its own rather than by enabling a repository on this machine.
	if ! has_libicu && { command -v dnf || command -v yum; } >/dev/null 2>&1; then
		note "installing libicu"
		install_package libicu
	fi
	has_libicu || fail "the runner needs libicu, which is not installed"
	ldconfig -p | grep -q 'libssl\.so' || fail "the runner needs OpenSSL, which is not installed"
fi
chown -R "$service_user:$service_user" "$work_dir"

# Nothing here registers the runner. An installed disk may be imaged and copied
# to other machines, and `config.sh` writes `.runner` and `.credentials` — the
# runner's own auth material — that every copy would then share. Registration is
# start-github-runner.sh's, once per machine.
note "complete dir=$work_dir user=$service_user"
