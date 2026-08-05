# docker

Installs the Docker engine from Docker's official apt repository.

```text
docker/
  artifact.yaml
  install-docker.sh
```

Install-only: there is no start phase. The install runs once as root during
pool-image bake, sets up Docker's apt repo (`docker-ce`, `docker-ce-cli`,
`containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`), and enables
the `docker` systemd service so the daemon starts on every clone boot.

## Parameters

None. This app takes no configuration.

## Platforms

- Linux amd64 and arm64 (Ubuntu/Debian via `apt-get`).

Ubuntu 26.04's codename may not yet exist in Docker's apt repo; the installer
falls back to the previous Ubuntu LTS codename (`noble`) and retries.

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
