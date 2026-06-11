# orc-apps

Source repository for ORC application artifacts published to `ghcr.io/admte/<app>`.

Each app is packaged as an OCI artifact per [orc-server spec 030](https://github.com/admte/orc-server/blob/main/specs/030-apps-contract.md) (`application/vnd.orc8r.app.v1`).

This repo holds app **sources** (config blobs, lifecycle scripts, helper binaries). Use [orc-app](https://github.com/admte/orc-app) or [orc-artifact](https://github.com/admte/orc-artifact) to pull and run them locally; orc-agent pulls them in production.

## Layout

```text
apps/
  shell/                 manifest-only app (config blob only)
    app.config.v1.json   OCI config blob (orc-artifact naming convention)
internal/                shared Go helpers and validation
go.mod
.github/workflows/       CI and release publishing
```

Config blobs use the filename `app.config.v1.json` so `orc-artifact push` discovers the correct media type (`application/vnd.orc8r.app.config.v1+json`).

## Apps

| App | Status | Notes |
|-----|--------|-------|
| shell | draft | Arbitrary shell command via `CMD_FILE` |
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

```bash
orc-artifact push ghcr.io/admte/shell:1.0.0,default \
  apps/shell/app.config.v1.json
```

Release tags use `<app>/<version>`, for example `shell/1.0.0`.

## Related repos

- **orc-app** - CLI to pull, install, start apps on your machine
- **orc-artifact** - OCI push/pull tool used in CI
- **orc-server** - orchestrator runtime and app contract specs
