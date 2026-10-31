#!/bin/sh
set -eu

SERVICE_USER=${SERVICE_USER:-ghrunner}

fail() {
	echo "github-runner install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# Installs a tool the image left out: minimal EL 9 and 10 cloud images ship
# without tar.
ensure_tool() {
	command -v "$1" >/dev/null 2>&1 && return 0
	echo "github-runner install: installing $1" >&2
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
	need "$1"
}

# The Actions runner refuses to configure or run as root ("Must not run with
# sudo"), but lifecycle phases execute as root. Create a dedicated service
# account here so start-github-runner.sh can drop to it.
ensure_service_user() {
	if id "$SERVICE_USER" >/dev/null 2>&1; then
		return 0
	fi
	need useradd
	useradd -r -U -M -s /usr/sbin/nologin "$SERVICE_USER"
	id "$SERVICE_USER" >/dev/null 2>&1 || fail "failed to create service user $SERVICE_USER"
}

# Selects the runner build GitHub's service wants for this target from the
# runner-downloads API response: prints "download_url filename sha256_checksum".
select_download() {
	python3 -c '
import json, sys
target_os, target_arch = sys.argv[1], sys.argv[2]
for entry in json.load(sys.stdin):
    if entry.get("os") == target_os and entry.get("architecture") == target_arch:
        print(entry.get("download_url", ""))
        print(entry.get("filename", ""))
        print(entry.get("sha256_checksum", ""))
        break
' "$1" "$2"
}

# Prints the token value, or nothing when none was delivered: install needs a
# credential only to ask GitHub's downloads API, and has a public path without one.
token_value() {
	if [ -n "${TOKEN_FILE:-}" ]; then
		tr -d '\r\n' <"$TOKEN_FILE"
	elif [ -n "${TOKEN:-}" ]; then
		printf '%s' "$TOKEN"
	fi
}

# The token param holds either an operator's personal access token or a
# registration orc8r minted for this node, a JSON object. They are told apart by
# shape: a value whose first non-blank character is `{` is the minted credential.
is_minted() {
	trimmed=${1#"${1%%[![:space:]]*}"}
	case "$trimmed" in
	'{'*) return 0 ;;
	*) return 1 ;;
	esac
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

github_api_path() {
	url=${URL:-}
	case "$url" in
	https://github.com/*) ;;
	*) fail "URL must start with https://github.com/" ;;
	esac
	path=${url#https://github.com/}
	path=${path%.git}
	path=${path%/}
	owner=${path%%/*}
	rest=${path#*/}
	[ -n "$owner" ] || fail "GitHub owner is required"
	if [ "$rest" != "$path" ] && [ -n "$rest" ]; then
		printf 'repos/%s/%s' "$owner" "$rest"
	else
		printf 'orgs/%s' "$owner"
	fi
}

runner_os() {
	case "$(uname -s)" in
	Linux) printf 'linux' ;;
	Darwin) printf 'osx' ;;
	*) fail "unsupported OS $(uname -s)" ;;
	esac
}

runner_arch() {
	case "$(uname -m)" in
	x86_64 | amd64) printf 'x64' ;;
	aarch64 | arm64) printf 'arm64' ;;
	*) fail "unsupported architecture $(uname -m)" ;;
	esac
}

[ "$(id -u)" -eq 0 ] || fail "must run as root"

need curl
need python3
# Not used here any more, but the start phase drops to the service account with
# it; a bake that produced an image without it would only fail at first boot.
need setpriv
ensure_tool tar

github_token=$(token_value)
work_dir=github-runner

ensure_service_user

mkdir -p "$work_dir"
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)

# The runner self-updates afterward, so no version pinning on either path.
if [ -n "$github_token" ] && ! is_minted "$github_token"; then
	# A personal access token: ask GitHub which runner build its service currently
	# wants for this registration target (authenticated: 5000 req/h vs 60).
	[ -n "${URL:-}" ] || fail "URL is required"
	api_path=$(github_api_path)
	downloads_json=$(curl -fsSL \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: token $github_token" \
		"https://api.github.com/$api_path/actions/runners/downloads") ||
		fail "failed to list runner downloads"
	selected=$(printf '%s' "$downloads_json" | select_download "$(runner_os)" "$(runner_arch)")
else
	# A minted registration, or none delivered yet: install holds no API
	# credential, so it takes the latest release from GitHub's public metadata.
	echo "github-runner install: no API token; using the latest public runner release" >&2
	release_json=$(curl -fsSL \
		-H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/actions/runner/releases/latest") ||
		fail "failed to read the latest runner release"
	selected=$(printf '%s' "$release_json" | select_release_asset "$(runner_os)" "$(runner_arch)")
fi
url=$(printf '%s\n' "$selected" | sed -n 1p)
archive=$(printf '%s\n' "$selected" | sed -n 2p)
checksum=$(printf '%s\n' "$selected" | sed -n 3p)
[ -n "$url" ] && [ -n "$archive" ] ||
	fail "no runner download for $(runner_os)/$(runner_arch)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "github-runner install: downloading the runner archive=$archive" >&2
curl -fsSL "$url" -o "$tmp/$archive"
if [ -n "$checksum" ]; then
	need sha256sum
	actual=$(sha256sum "$tmp/$archive" | awk '{ print $1 }')
	[ "$actual" = "$checksum" ] ||
		fail "checksum mismatch archive=$archive expected=$checksum actual=$actual"
	echo "github-runner install: checksum verified archive=$archive" >&2
else
	echo "github-runner install: no published checksum; skipping verification archive=$archive" >&2
fi
tar -xzf "$tmp/$archive" -C "$work_dir"

# The runner is a .NET program that exits at first start without libicu and the
# other libraries .NET needs, and Debian 13 and EL images ship without libicu.
# The runner carries its own installer for them, which knows each distribution's
# package names.
# The installer is all or nothing, though, so it may fail over a package the
# runner can do without; what decides is whether the libraries are there after.
if [ "$(runner_os)" = linux ]; then
	echo "github-runner install: installing the runner's dependencies" >&2
	DEBIAN_FRONTEND=noninteractive "$work_dir/bin/installdependencies.sh" >&2 ||
		echo "github-runner install: the runner's dependency installer failed; checking its libraries" >&2
	# The trace provider's lttng is optional, and .NET opens ICU and OpenSSL at
	# run time, so ldd cannot see those two.
	missing=$(for lib in "$work_dir"/bin/*.so; do
		[ "${lib##*/}" = libcoreclrtraceptprovider.so ] || ldd "$lib" 2>/dev/null
	done | awk '/not found/ { print $1 }' | sort -u | tr '\n' ' ')
	[ -z "$missing" ] || fail "the runner's libraries are missing: $missing"
	ldconfig -p | grep -q 'libicuuc\.so' || fail "the runner needs libicu, which is not installed"
	ldconfig -p | grep -q 'libssl\.so' || fail "the runner needs OpenSSL, which is not installed"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$work_dir"

# Nothing below this point may create node identity. A pool bake runs the install
# phase alone and snapshots the disk, so anything written here is shared by every
# clone of the image: registering would leave a dead runner on GitHub for a
# builder that no longer exists, and `config.sh` writes `.runner` and
# `.credentials` — the runner's own auth material — into the snapshot. The
# registration is start-github-runner.sh's, once per node.
echo "github-runner install: complete dir=$work_dir user=$SERVICE_USER" >&2
