# apt

Linux-only app that installs Debian/Ubuntu packages via `apt-get`. Defined by a single
`artifact.yaml` plus two lifecycle scripts shipped as OCI layers (`files:`).

```text
apt/
  artifact.yaml      # linux/amd64
  install-apt.sh     # validate OS, apt-get, package names
  start-apt.sh       # apt-get update && install
```

| Param | Description |
|-------|-------------|
| `packages` | Space-separated package names (e.g. `git curl htop`) |

Platform: **linux/amd64** only (`apt-get` is Debian/Ubuntu-specific).

Build + push (from the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`):

```bash
./orc build ./apps/apt --push
```
