# shell

Multi-platform app. Each platform directory holds `app.config.v1.json` (required by `orc-artifact push`).

```text
shell/
  linux/app.config.v1.json    → linux/amd64
  windows/app.config.v1.json  → windows/amd64
```

| Directory | `cmd` param syntax |
|-----------|-------------------|
| `linux/` | POSIX shell (`text/x-sh`) |
| `windows/` | cmd.exe (`text/plain`) |

Publish all platforms: `make push-shell` from the repo root.

Linux-only:

```bash
orc-artifact push ghcr.io/admte/shell:1.0.0,default apps/shell/linux/app.config.v1.json
```
