# gitleaks

Version-scoped install of the Gitleaks secret scanner.

```text
gitleaks/
  artifact.yaml
  install-gitleaks.sh     uninstall-gitleaks.sh
  install-gitleaks.ps1    uninstall-gitleaks.ps1
```

No parameters. Gitleaks is a single binary configured per invocation, so there is nothing
for an operator to set at install time.

## Installation

The release archive and the project's `checksums.txt` are both downloaded, and the
archive is verified against the line for its own file name before anything is unpacked —
the same thing `trivy`, `terraform`, `vault` and `aws` do.

The binary goes to `/opt/gitleaks/<version>` on Linux, with `gitleaks` symlinked into
`/usr/local/bin`; the symlink is swapped atomically so a concurrent call never sees a
missing PATH entry. On Windows it goes to `%ProgramFiles%\gitleaks\<version>`, with a
`current` junction and one machine PATH entry pointing at the junction — so switching
versions never rewrites the PATH.

If the requested version is already on disk and runs, install repoints the symlink or
junction and stops there. That matters because the pool image is baked straight after the
install phase and every node is then rebuilt from it, which runs install again on a disk
that already carries the binary.

The binary is located by searching the unpacked archive rather than by assuming a path.

## Versioning

`config.versions` reads the project's GitHub releases, the same source `uv`,
`terraform` and `vault` use. The tags carry a leading `v` that the release files do not, so `v8.30.1` is offered
as `8.30.1` and the scripts put the `v` back when building the download URL.

Selecting `default` installs the newest release: `APP_VERSION` arrives unset in that case
and the scripts ask the project which release is current.

## File naming

The project's own names, taken from its checksums file:

| Platform | Archive |
|----------|---------|
| Linux amd64 | `gitleaks_<version>_linux_x64.tar.gz` |
| Linux arm64 | `gitleaks_<version>_linux_arm64.tar.gz` |
| Windows amd64 | `gitleaks_<version>_windows_x64.zip` |
| Windows arm64 | `gitleaks_<version>_windows_arm64.zip` |

Worth noting against `trivy`, which is otherwise the same kind of package and spells
every one of these differently: `Linux-64bit` against `linux_x64`, capitalised against
lower case, hyphen against underscore. Neither set is guessable from the other.

## Uninstall

Removes that version's tree. The exposure symlink, or the junction and its PATH entry,
are dropped only while they still point into this version's own tree.

## Platforms

Linux amd64 and arm64, Windows amd64 and arm64 — all four are published.

## Requirements

- Linux: root, `curl` and `tar`. Windows: Administrator.
- Outbound HTTPS to `github.com` and, for the `default` tag, `api.github.com`.

## Build

```bash
./orc build ./apps/gitleaks --output /tmp/gitleaks-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
GITLEAKS_INSTALL_ROOT="$tmp/gitleaks" GITLEAKS_BIN_DIR="$tmp/bin" APP_VERSION=8.30.1 \
  sh apps/gitleaks/install-gitleaks.sh
"$tmp/bin/gitleaks" version
GITLEAKS_INSTALL_ROOT="$tmp/gitleaks" GITLEAKS_BIN_DIR="$tmp/bin" APP_VERSION=8.30.1 \
  sh apps/gitleaks/uninstall-gitleaks.sh
rm -rf "$tmp"
```
