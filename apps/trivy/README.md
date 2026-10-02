# trivy

Version-scoped install of the Trivy security scanner.

```text
trivy/
  artifact.yaml
  install-trivy.sh     uninstall-trivy.sh
  install-trivy.ps1    uninstall-trivy.ps1
```

No parameters. Trivy is a single binary that is configured per invocation, so there is
nothing for an operator to set at install time.

## Installation

The release archive and the project's `checksums.txt` are both downloaded, and the
archive is verified against the line for its own file name before anything is unpacked —
the same thing `terraform`, `vault` and `aws` do.

The binary goes to `/opt/trivy/<version>` on Linux, with `trivy` symlinked into
`/usr/local/bin`; the symlink is swapped atomically so a concurrent call never sees a
missing PATH entry. On Windows it goes to `%ProgramFiles%\trivy\<version>`, with a
`current` junction and one machine PATH entry pointing at the junction — so switching
versions never rewrites the PATH. `go`, `java` and `node` are laid out the same way.

The binary is located by searching the unpacked archive rather than by assuming a path:
the archive also carries a licence and contrib files, and its layout is the project's to
change.

## Versioning

`config.versions` reads the project's GitHub releases. The tags carry a leading `v` that
the release files do not, so `v0.74.0` is offered as `0.74.0` and the scripts put the `v`
back when building the download URL.

Selecting `default` installs the newest release: `APP_VERSION` arrives unset in that case
and the scripts ask the project which release is current, rather than failing the way
`go` does.

## File naming

The project's own names, taken from its checksums file, are not uniform and are easy to
get wrong:

| Platform | Archive |
|----------|---------|
| Linux amd64 | `trivy_<version>_Linux-64bit.tar.gz` |
| Linux arm64 | `trivy_<version>_Linux-ARM64.tar.gz` |
| Windows amd64 | `trivy_<version>_windows-64bit.zip` |

`Linux` and `macOS` are capitalised while `windows` is not, the 64-bit build is called
`64bit` rather than `amd64`, and arm64 is written `ARM64`.

## Uninstall

Removes that version's tree. The exposure symlink, or the junction and its PATH entry,
are dropped only while they still point into this version's own tree — a newer version
installed alongside this one has already repointed them and keeps them.

## Platforms

Linux amd64 and arm64, Windows amd64. The project publishes a single Windows archive and
no arm64 one.

## Requirements

- Linux: root, `curl` and `tar`. Windows: Administrator.
- Outbound HTTPS to `github.com` and, for the `default` tag, `api.github.com`.

## Build

```bash
./orc build ./apps/trivy --output /tmp/trivy-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
TRIVY_INSTALL_ROOT="$tmp/trivy" TRIVY_BIN_DIR="$tmp/bin" APP_VERSION=0.74.0 \
  sh apps/trivy/install-trivy.sh
"$tmp/bin/trivy" --version
TRIVY_INSTALL_ROOT="$tmp/trivy" TRIVY_BIN_DIR="$tmp/bin" APP_VERSION=0.74.0 \
  sh apps/trivy/uninstall-trivy.sh
rm -rf "$tmp"
```
