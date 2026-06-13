# orc-apps

Source repository for ORC application artifacts published to `ghcr.io/admte/<app>`.

Each app is packaged as an OCI artifact per [orc-server spec 030](https://github.com/admte/orc-server/blob/main/specs/030-apps-contract.md) (`application/vnd.orc8r.app.v1`).

This repo holds app **sources** (config blobs, lifecycle scripts, helper binaries). Use [orc-app](https://github.com/admte/orc-app) or [orc-artifact](https://github.com/admte/orc-artifact) to pull and run them locally; orc-agent pulls them in production.

## Layout

```text
apps/
  shell/
    linux/app.config.v1.json
    windows/app.config.v1.json
internal/                shared Go helpers and validation
go.mod
.github/workflows/       CI and release publishing
```

Each platform directory contains `app.config.v1.json` — the filename `orc-artifact push` expects.

## Apps

| App | Status | Notes |
|-----|--------|-------|
| shell | draft | Arbitrary command via `CMD_FILE`; linux + windows (multi-platform index) |
| apt | planned | |
| cppdevtools | planned | |
| uv | planned | |
| github-runner | planned | |
| jenkins-agent | planned | |
| kvm-server | planned | JSON-RPC plugin (spec 031) |

`pxenode` stays in orc-server.

## Development

```bash
make test      # validate all app.config.v1.json blobs
make tidy      # refresh go.sum
```

### Publish shell locally (after orc-artifact login)

Multi-platform (linux amd64 + windows amd64):

```bash
make push-shell
```

Linux-only:

```bash
orc-artifact push ghcr.io/admte/shell:1.0.0,default \
  apps/shell/linux/app.config.v1.json
```

Release tags use `<app>/<version>`, for example `shell/1.0.0`.

## Related repos

- **orc-app** - CLI to pull, install, start apps on your machine
- **orc-artifact** - OCI push/pull tool used in CI
- **orc-server** - orchestrator runtime and app contract specs
