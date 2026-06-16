# orc-apps

Source repository for ORC application artifacts published to `ghcr.io/admte/<app>`.

Each app is packaged as an OCI artifact per [orc-server spec 030](https://github.com/admte/orc-server/blob/main/specs/030-apps-contract.md) (`application/vnd.orc8r.app.v1`) using the [`orc`](https://github.com/admte/orc-cli) CLI.

This repo holds app **sources** (config, lifecycle scripts, helper binaries) as one
`artifact.yaml` recipe per app. orc-agent pulls the published artifacts in production.

## Layout

```text
apps/
  shell/
    artifact.yaml          # recipe: config + platforms (linux + windows)
  apt/
    artifact.yaml          # recipe: config + files (install/start scripts)
    install-apt.sh
    start-apt.sh
scripts/install.sh         # downloads the orc CLI into ./orc
.github/workflows/ci.yml   # validate on PR, publish on <app>/<version> tags
```

Each app is a directory under `apps/` containing an `artifact.yaml`. There are no more
per-platform `app.config.v1.json` files — multi-platform differences are expressed with
`platforms[].vars` and `{var}` interpolation inside `config:`.

## artifact.yaml

```yaml
artifactType: application/vnd.orc8r.app.v1
annotations:
  org.opencontainers.image.title: shell        # -> ghcr.io/admte/shell   (the OCI repository)
  # org.opencontainers.image.version: 1.0.1    # optional; omitted -> tag "default"
config:
  # the app config blob (application/vnd.orc8r.app.config.v1+json)
  ...
files:                                          # extra payload files -> OCI layers (optional)
  - install-apt.sh
platforms:                                      # one manifest per platform (optional)
  - os: linux
    arch: amd64
    vars: { ... }                               # substituted into config via {var}
```

`orc build` derives the OCI reference from the annotations:
`org.opencontainers.image.title` is the repository and `org.opencontainers.image.version`
is the tag (defaulting to `default`). Pass `--tag` to override.

## Workflow

```bash
# 1. install the orc CLI into ./orc (gitignored)
./scripts/install.sh

# 2. authenticate to the registry (once)
./orc login ghcr.io

# 3. build (ref derived from artifact.yaml) and push
./orc build ./apps/shell
./orc push shell:default

# or build + push in one step (docker buildx style)
./orc build ./apps/shell --push
./orc build ./apps/apt   --push
```

Pin a version with the annotation `org.opencontainers.image.version`, or override at build
time: `./orc build ./apps/shell --tag shell:1.0.1,default --push`.

Validate locally without pushing (writes an OCI layout to disk):

```bash
./orc build ./apps/shell --output /tmp/shell-oci
```

## CI

- **PRs / pushes:** every `apps/*/` is built to validate `artifact.yaml` and the config schema.
- **Release:** push a tag `<app>/<version>` (e.g. `shell/1.0.1`) to build and push that app to
  `ghcr.io/admte/<app>:<version>,default`.

## Apps

| App | Status | Notes |
|-----|--------|-------|
| shell | draft | Arbitrary command via `CMD_FILE`; linux + windows (multi-platform index) |
| apt | draft | Install Debian/Ubuntu packages via `apt-get`; linux only |
| cppdevtools | planned | |
| uv | planned | |
| github-runner | planned | |
| jenkins-agent | planned | |
| kvm-server | planned | JSON-RPC plugin (spec 031) |

`pxenode` stays in orc-server.

## Related repos

- **orc-cli** - the `orc` CLI used to build/push/pull/run apps
- **orc-rs** - Rust core (`orc-app`) the CLI builds on
- **orc-server** - orchestrator runtime and app contract specs
