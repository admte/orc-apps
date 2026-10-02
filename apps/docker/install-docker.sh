#!/bin/sh
set -eu

fail() {
	echo "docker install: $*" >&2
	exit 1
}

# Already installed: nothing to do. Keeps pool-image bakes idempotent.
if command -v docker >/dev/null 2>&1; then
	docker --version >&2
	exit 0
fi

[ "$(id -u)" -eq 0 ] || fail "must run as root"
command -v systemctl >/dev/null 2>&1 || fail "systemctl is required"

# Docker publishes distro-specific APT and RHEL-compatible RPM repositories.
distro=ubuntu
codename=""
if [ -r /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	[ -n "${ID:-}" ] && distro=$ID
	codename=${VERSION_CODENAME:-}
fi
case "$distro" in
almalinux | rhel | rocky | centos)
	command -v dnf >/dev/null 2>&1 || fail "dnf is required on $distro"
	echo "Configuring Docker's RHEL repository for $distro" >&2
	dnf -y install dnf-plugins-core ca-certificates
	dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
	dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	;;
ubuntu | debian)
	command -v apt-get >/dev/null 2>&1 || fail "apt-get is required on $distro"
	[ -n "$codename" ] || fail "could not determine release codename from /etc/os-release"
	arch=$(dpkg --print-architecture)

	# Prerequisites for fetching the signing key and adding the repo.
	echo "Installing prerequisites (ca-certificates, curl)" >&2
	DEBIAN_FRONTEND=noninteractive apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl

	# Install the Docker signing key.
	echo "Installing Docker signing key" >&2
	mkdir -p /etc/apt/keyrings
	curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc

	# Write the repo definition for a given codename and try to install from it.
	# Primary path and fallback share this one function; a failure returns non-zero
	# so the caller can retry with a different codename rather than aborting.
	install_from_repo() {
		repo_codename=$1
		echo "Configuring Docker apt repo for $distro/$repo_codename ($arch)" >&2
		printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
			"$arch" "$distro" "$repo_codename" >/etc/apt/sources.list.d/docker.list
		DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
			docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
	}

	# Newer releases (e.g. Ubuntu 26.04) may not have a Docker repo yet; fall back
	# to the previous Ubuntu LTS codename ("noble"), whose packages are compatible.
	if ! install_from_repo "$codename"; then
		[ "$distro" = ubuntu ] || fail "Docker repository unavailable for $distro/$codename"
		echo "Docker repo for '$codename' unavailable; falling back to 'noble'" >&2
		install_from_repo noble || fail "docker-ce installation failed for both '$codename' and 'noble'"
	fi
	;;
*) fail "unsupported distribution: $distro" ;;
esac

echo "Enabling and starting the docker service" >&2
systemctl enable --now docker

# The daemon can take a moment to accept connections after start.
i=0
until docker info >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -ge 10 ] && fail "docker daemon did not become ready"
	sleep 2
done

docker --version >&2
echo "Docker engine installed" >&2
