#!/bin/sh
set -eu

# Installs one Argo CD CLI release into its own directory and exposes it through a symlink,
# the same shape cosign, snyk, trivy, syft, gitleaks, k6 and osv-scanner use.
#
# The CLI only. An Argo CD release also carries the server, which runs in Kubernetes and
# is not something a node installs; the `argocd-*` assets are the command-line client.
#
# Like cosign, snyk and osv-scanner, the project publishes bare executables rather than
# archives, so there is nothing to unpack. The checksums come as one file for the whole
# release — cli_checksums.txt — as trivy's and osv-scanner's do, rather than one file per
# asset as snyk's do.

fail() {
	echo "argocd install: $*" >&2
	exit 1
}

# Progress goes to stdout: the node log shows an install's stderr as warnings, and a
# healthy install has nothing to warn about.
note() {
	echo "argocd install: $*"
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

need curl
need mktemp

case "$(uname -s)" in
Linux) ;;
*) fail "unsupported operating system: $(uname -s)" ;;
esac

# The architecture is part of the asset name, so it is resolved here rather than by a
# generic "linux" asset.
case "$(uname -m)" in
x86_64 | amd64) asset=argocd-linux-amd64 ;;
aarch64 | arm64) asset=argocd-linux-arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

version=${APP_VERSION:-}
if [ -z "$version" ]; then
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag,
	# so the newest release is asked of the project rather than guessed.
	note "no version was requested; taking the newest release"
	latest=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest) ||
		fail "could not read the newest release from GitHub"
	version=$(printf '%s' "$latest" |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' |
		head -1)
	[ -n "$version" ] || fail "the release response names no version"
	note "newest release is $version"
fi
version=${version#v}

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

root=${ARGOCD_INSTALL_ROOT:-/opt/argocd}
bin_dir=${ARGOCD_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"
link="$bin_dir/argocd"

work=$(mktemp -d)
tmp_link="$bin_dir/.argocd.orc.$$"
trap 'rm -rf "$work" "$tmp_link"' EXIT HUP INT TERM

# Repoints the exposure symlink atomically, so a concurrent `argocd` call never sees
# a missing PATH entry while versions are switched.
expose() {
	mkdir -p "$bin_dir"
	[ ! -d "$link" ] || fail "$link is a directory"
	rm -f "$tmp_link"
	ln -s "$prefix/argocd" "$tmp_link"
	mv -f "$tmp_link" "$link"
}

# `version --client` and not the plain `version`: the plain form tries to reach an Argo CD
# server and only then prints the client version, so on a node with nothing configured it
# would wait on a connection that is not the point here.
reported_version() {
	"$1" version --client 2>/dev/null || "$1" --version 2>/dev/null || return 1
}

# Already here? The pool image is baked straight after this phase and the node is then
# rebuilt from that image, which runs this phase again on a disk that already carries the
# binary. Without this check every node downloads what it is already holding.
if [ -x "$prefix/argocd" ] && reported=$(reported_version "$prefix/argocd"); then
	case "$reported" in
	*"$version"*)
		expose
		note "argocd $version is already installed"
		exit 0
		;;
	esac
fi

# One checksums file for every asset in the release.
sums=cli_checksums.txt
base="https://github.com/argoproj/argo-cd/releases/download/v$version"

note "downloading $asset"
curl -fsSL "$base/$asset" -o "$work/$asset" || fail "could not download $asset"
curl -fsSL "$base/$sums" -o "$work/$sums" || fail "could not download $sums"

# Matched on the whole name with awk's exact field comparison. The file lists every
# platform the project builds — darwin, ppc64le and s390x among them — so a prefix match
# would be ambiguous the day a suffixed variant appears. The ./ spelling is allowed for
# because mise's release writes its names that way; this one does not, and the match
# stays exact either way.
expected=$(awk -v asset="$asset" '$2 == asset || $2 == "./" asset { print $1 }' "$work/$sums")
[ -n "$expected" ] || fail "checksum for $asset was not published"

if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
	actual=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
else
	fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

# Claim only this version's own subtree: /opt/argocd may already hold other versions.
mkdir -p "$prefix"
install -m 0755 "$work/$asset" "$prefix/argocd"

expose

reported=$(reported_version "$prefix/argocd") || fail "argocd does not run on this node"
case "$reported" in
*"$version"*) ;;
*) fail "installed version '$reported' does not match $version" ;;
esac

note "argocd $version installed at $prefix"
