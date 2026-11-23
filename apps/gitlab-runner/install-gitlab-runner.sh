#!/bin/sh
set -eu

# Downloads GitLab Runner 19.6.0, checks it against the checksum pinned here,
# and creates the account jobs run as. It takes no url and no token and writes
# no runner configuration: an installed disk may be copied to other machines.

RUNNER_VERSION=19.6.0
DOWNLOADS=https://gitlab-runner-downloads.s3.amazonaws.com

usage() {
	cat <<'USAGE'
Usage: install-gitlab-runner.sh --arch=ARCH [--user=NAME]

Downloads GitLab Runner 19.6.0 into this directory, verifies its checksum and
creates the account jobs run as. Configures no runner. Run as root.

  --arch=ARCH   amd64 or arm64
  --user=NAME   account jobs run as, created if missing (default: gitlab-runner)
  --help        show this help
USAGE
}

fail() {
	echo "gitlab-runner install: $*" >&2
	exit 1
}

usage_error() {
	echo "gitlab-runner install: $*" >&2
	usage >&2
	exit 2
}

note() {
	echo "gitlab-runner install: $*"
}

arch=
user=gitlab-runner
for arg; do
	case $arg in
	--arch=*) arch=${arg#--arch=} ;;
	--user=*) user=${arg#--user=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

# The SHA-256 of each build, from the release's signed release.sha256.
case $arch in
amd64) checksum=295f0d264b540286e1d1ede2bd572f890269e2a4977c7a656a3f71280845bc2f ;;
arm64) checksum=a7d29d619beb3d20134cbcd8abfe2cbdb34d9caa626dfdba8fe0206b99f677ff ;;
'') usage_error "--arch is required" ;;
*) fail "unsupported architecture $arch" ;;
esac
[ -n "$user" ] || usage_error "--user must not be empty"
[ "$(id -u)" -eq 0 ] || fail "must run as root"

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

install_package() {
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get update -qq
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q "$@"
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q "$@"
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive --quiet install "$@"
	else
		fail "$* required and no supported package manager was found"
	fi
}

need curl
need sha256sum
need useradd
# Jobs need git to fetch their sources, bash for the shell executor, and su to
# run as $user.
for tool in git bash; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		note "installing $tool"
		install_package "$tool"
		need "$tool"
	fi
done
need su

if ! id "$user" >/dev/null 2>&1; then
	useradd --comment 'GitLab Runner' --create-home --shell /bin/bash "$user"
	id "$user" >/dev/null 2>&1 || fail "failed to create the account $user"
fi
# A .bash_logout that clears the screen fails every job of the shell executor.
home=$(getent passwd "$user" | cut -d: -f6)
[ -z "$home" ] || rm -f "$home/.bash_logout"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 1' HUP INT TERM

asset=gitlab-runner-linux-$arch
note "downloading GitLab Runner $RUNNER_VERSION asset=$asset"
curl -fsSL "$DOWNLOADS/v$RUNNER_VERSION/binaries/$asset" -o "$tmp/$asset" ||
	fail "could not download $asset"
actual=$(sha256sum "$tmp/$asset" | awk '{ print $1 }')
[ "$actual" = "$checksum" ] ||
	fail "checksum mismatch asset=$asset expected=$checksum actual=$actual"
chmod 0755 "$tmp/$asset"
"$tmp/$asset" --version | grep -q "^Version: *$RUNNER_VERSION\$" ||
	fail "the downloaded runner does not report version $RUNNER_VERSION"

install -m 0755 "$tmp/$asset" ./gitlab-runner
install -m 0755 "./gitlab-runner-handover-$arch" ./gitlab-runner-handover
note "installed version=$RUNNER_VERSION dir=$(pwd) user=$user"
