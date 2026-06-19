# uv

Installs the [uv](https://github.com/astral-sh/uv) Python package manager using Astral's
official installer scripts (matching the in-process builtin in orc-server).

```text
uv/
  artifact.yaml
  install-uv-unix.sh   # linux + darwin → /usr/local/bin/uv
  install-uv.ps1       # windows
```

No operator parameters. Installation runs in the **install** phase because uv is a CLI tool,
not a long-running service.

| Platform | Notes |
|----------|-------|
| linux | requires root; installs to `/usr/local/bin/uv` |
| darwin | installs to `/usr/local/bin/uv` |
| windows | user-level install via official PowerShell script |

Build + push (from the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`):

```bash
./orc build ./apps/uv --push
```

Test on Ubuntu (needs root for first install):

```bash
sudo sh apps/uv/install-uv-unix.sh
uv --version
```

Or pull the published artifact to verify its payload:

```bash
./orc pull uv:default /tmp/uv-pull
find /tmp/uv-pull -maxdepth 2 -type f -print
```
