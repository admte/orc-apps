# docker

Installs the Docker engine from Docker's official apt or RPM repository.

```text
docker/
  artifact.yaml
  install-docker.sh
```

Install-only: there is no start phase. Installation runs as root and sets up Docker's
repo (`docker-ce`, `docker-ce-cli`,
`containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`), and enables
the Docker systemd service and socket. A generalized EL10 clone can apply vendor
presets at first boot and start the daemon through `docker.socket` when first used.

## Parameters

None. This app takes no configuration.

## Platforms

- Linux amd64 and arm64 (Ubuntu/Debian via `apt-get`).
- AlmaLinux 9/10 and RHEL-compatible systems via `dnf` and Docker's RHEL repository.

On EL10 cloud images, installation adds `kernel-modules-extra` for the running
kernel when its iptables `addrtype` extension is missing. RPM installation
skips weak dependencies to avoid pulling an unrelated debug kernel.

Ubuntu 26.04's codename may not yet exist in Docker's apt repo; the installer
falls back to the previous Ubuntu LTS codename (`noble`) and retries. Debian never
falls back to an Ubuntu repository.

## Used by other apps

Apps that need a container runtime depend on Docker being present rather than
installing it themselves. They probe `command -v docker` to detect the engine,
and may pre-claim the `docker` group with `groupadd -f docker` before adding a
service account to it, so group membership is stable regardless of install order.

## Build + Push

From the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`:

```bash
./orc build ./apps/docker --push
```

Validate locally without pushing:

```bash
./orc build ./apps/docker --output /tmp/docker-oci
```
