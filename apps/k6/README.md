# k6

Version-scoped install of the Grafana k6 load testing tool.

```text
k6/
  artifact.yaml
  install-k6.sh     uninstall-k6.sh
  install-k6.ps1    uninstall-k6.ps1
```

No parameters. k6 is a single binary that takes its work from the script it is given.

## Installation

The release archive and the project's checksums file are both downloaded, and the
archive is verified against the line for its own file name before anything is unpacked —
the same thing `trivy`, `syft`, `terraform` and `vault` do.

The binary goes to `/opt/k6/<version>` on Linux, with `k6` symlinked into
`/usr/local/bin`; the symlink is swapped atomically. On Windows it goes to
`%ProgramFiles%\k6\<version>`, with a `current` junction and one machine PATH entry
pointing at the junction, so switching versions never rewrites the PATH.

On Windows the project publishes an `.msi` beside the `.zip`. This package takes the
zip: an MSI would install through Windows Installer, outside this app's own directory
and outside its uninstall.

The binary is located by searching the unpacked archive — k6 puts it inside a directory
named after the build.

## Versioning

`config.versions` reads the project's GitHub tags. The tags carry a leading `v`, which
is stripped for display, and the scripts put it back when building the download URL.

Selecting `default` installs the newest release.

## File naming

| Platform | Archive |
|----------|---------|
| Linux amd64 | `k6-v<version>-linux-amd64.tar.gz` |
| Linux arm64 | `k6-v<version>-linux-arm64.tar.gz` |
| Windows amd64 | `k6-v<version>-windows-amd64.zip` |

Note the `v` **inside** the file name. `trivy`, `gitleaks` and `syft` all write the bare
number there, and all three use different separators besides. Four packages of the same
kind, four spellings — each copied from the project's own checksums file rather than
inferred from the others.

## Platforms

Linux amd64 and arm64, Windows amd64. The project publishes no Windows arm64 build.

## Uninstall

Removes that version's tree. The exposure symlink, or the junction and its PATH entry,
are dropped only while they still point into this version's own tree.

## Requirements

- Linux: root, `curl` and `tar`. Windows: Administrator.
- Outbound HTTPS to `github.com` and, for the `default` tag, `api.github.com`.

## Build

```bash
./orc build ./apps/k6 --output /tmp/k6-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
K6_INSTALL_ROOT="$tmp/k6" K6_BIN_DIR="$tmp/bin" APP_VERSION=2.2.0 \
  sh apps/k6/install-k6.sh
"$tmp/bin/k6" version
K6_INSTALL_ROOT="$tmp/k6" K6_BIN_DIR="$tmp/bin" APP_VERSION=2.2.0 \
  sh apps/k6/uninstall-k6.sh
rm -rf "$tmp"
```
