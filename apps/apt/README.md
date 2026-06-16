# apt

Linux-only app that installs Debian/Ubuntu packages via `apt-get`.

```text
apt/
  linux/app.config.v1.json
  linux/install-apt.sh   # validate OS, apt-get, package names
  linux/start-apt.sh     # apt-get update && install
```

| Param | Description |
|-------|-------------|
| `packages` | Space-separated package names (e.g. `git curl htop`) |

Platform: **linux/amd64** only (no Windows — `apt-get` is Debian/Ubuntu-specific).

Publish:

```bash
make push-apt
```

Linux-only manual push:

```bash
orc-artifact push -platform linux/amd64 ghcr.io/admte/apt:1.0.0,default \
  apps/apt/linux/app.config.v1.json \
  apps/apt/linux/install-apt.sh \
  apps/apt/linux/start-apt.sh
```
