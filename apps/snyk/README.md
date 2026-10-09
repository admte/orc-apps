# snyk

Version-scoped install of the Snyk CLI.

```text
snyk/
  artifact.yaml
  install-snyk.sh     uninstall-snyk.sh
  install-snyk.ps1    uninstall-snyk.ps1
```

No parameters. The CLI is installed, not authenticated: `snyk auth` and `SNYK_TOKEN`
belong to the job that runs a scan, so no token is ever handled by this package.

## Installation

Snyk publishes **bare executables**, not archives — `snyk-linux`, `snyk-win.exe` — so, as
with `cosign`, there is nothing to unpack: the download is the binary.

Each binary carries its own checksum file beside it (`snyk-linux.sha256`), rather than one
combined file for the release. The release also ships `sha256sums.txt.asc`, but that is
PGP-signed text and verifying it would need the project's key on the node, so the
per-asset file is used instead.

The match is anchored on the whole file name: `snyk-linux` is a prefix of
`snyk-linux-arm64`, and so are their checksum file names.

The binary goes to `/opt/snyk/<version>` on Linux, with `snyk` symlinked into
`/usr/local/bin`; the symlink is swapped atomically. On Windows it goes to
`%ProgramFiles%\snyk\<version>`, with a `current` junction and one machine PATH entry
pointing at the junction.

If the requested version is already on disk and runs, install repoints the symlink or
junction and stops there — the pool image is baked straight after this phase and every
node is then rebuilt from it, which runs install again on a disk that already has the
binary.

## Versioning

`config.versions` reads the project's GitHub releases. Snyk ships many times a week, so
the list is one entry per minor, like `trivy` — thirty raw releases would all be from the
same fortnight.

The tags carry a leading `v`; the scripts accept the version written either way and put
the `v` back when building the download URL.

Selecting `default` installs the newest release.

## Platforms

Linux amd64 and arm64, Windows amd64. The project publishes no Windows arm64 binary.

Snyk also ships `snyk-alpine` and `snyk-alpine-arm64`, built against musl. These nodes are
glibc, so those assets are never the right ones here.

## Uninstall

Removes that version's tree. The exposure symlink, or the junction and its PATH entry, are
dropped only while they still point into this version's own tree — the runtime installs
the new version *before* running the superseded version's uninstall.

## Requirements

- Linux: root and `curl`. Windows: Administrator.
- Outbound HTTPS to `github.com` and, for the `default` tag, `api.github.com`.

## Licensing

The Snyk CLI is not open-source software; commercial use is governed by Snyk's own terms
and may require a paid plan. This package installs the CLI and takes no position on
entitlement.

## Build

```bash
./orc build ./apps/snyk --output /tmp/snyk-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
SNYK_INSTALL_ROOT="$tmp/snyk" SNYK_BIN_DIR="$tmp/bin" APP_VERSION=1.1308.0 \
  sh apps/snyk/install-snyk.sh
"$tmp/bin/snyk" --version
SNYK_INSTALL_ROOT="$tmp/snyk" SNYK_BIN_DIR="$tmp/bin" APP_VERSION=1.1308.0 \
  sh apps/snyk/uninstall-snyk.sh
rm -rf "$tmp"
```
