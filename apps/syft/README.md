# syft

Version-scoped install of the Syft SBOM generator.

```text
syft/
  artifact.yaml
  install-syft.sh     uninstall-syft.sh
  install-syft.ps1    uninstall-syft.ps1
```

No parameters. Syft is a single binary configured per invocation.

## Installation

The release archive and the project's `checksums.txt` are both downloaded, and the
archive is verified against the line for its own file name before anything is unpacked —
the same thing `trivy`, `terraform`, `vault` and `aws` do. The match is anchored on the
whole file name, which matters here: every archive has an `.sbom` file published beside
it under a nearly identical name.

The binary goes to `/opt/syft/<version>` on Linux, with `syft` symlinked into
`/usr/local/bin`; the symlink is swapped atomically. On Windows it goes to
`%ProgramFiles%\syft\<version>`, with a `current` junction and one machine PATH entry
pointing at the junction, so switching versions never rewrites the PATH.

If the requested version is already on disk and runs, install repoints the symlink or
junction and stops there — the pool image is baked straight after this phase and every
node is then rebuilt from it, which runs install again on a disk that already has the
binary.

## Versioning

`config.versions` reads the project's GitHub releases, the same source `uv`,
`terraform` and `vault` use. The tags carry a leading `v` that the release files do not, so `v1.52.0` is offered
as `1.52.0` and the scripts put the `v` back.

Selecting `default` installs the newest release.

## File naming

| Platform | Archive |
|----------|---------|
| Linux amd64 | `syft_<version>_linux_amd64.tar.gz` |
| Linux arm64 | `syft_<version>_linux_arm64.tar.gz` |
| Windows amd64 | `syft_<version>_windows_amd64.zip` |
| Windows arm64 | `syft_<version>_windows_arm64.zip` |

Plain `amd64` and `arm64` here, where `trivy` writes `Linux-64bit` and `gitleaks` writes
`linux_x64`. Three packages of the same kind, three different spellings — none of them
guessable from the others, so each was copied from the project's own checksums file.

## Platforms

Linux amd64 and arm64, Windows amd64 and arm64 — every platform the project publishes a
build for, which is what `go`, `node` and `uv` do.

## Uninstall

Removes that version's tree. The exposure symlink, or the junction and its PATH entry,
are dropped only while they still point into this version's own tree.

## Requirements

- Linux: root, `curl` and `tar`. Windows: Administrator.
- Outbound HTTPS to `github.com` and, for the `default` tag, `api.github.com`.

## Build

```bash
./orc build ./apps/syft --output /tmp/syft-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
SYFT_INSTALL_ROOT="$tmp/syft" SYFT_BIN_DIR="$tmp/bin" APP_VERSION=1.52.0 \
  sh apps/syft/install-syft.sh
"$tmp/bin/syft" version
SYFT_INSTALL_ROOT="$tmp/syft" SYFT_BIN_DIR="$tmp/bin" APP_VERSION=1.52.0 \
  sh apps/syft/uninstall-syft.sh
rm -rf "$tmp"
```
