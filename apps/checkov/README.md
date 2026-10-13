# checkov

Version-scoped install of Checkov.

```text
checkov/
  artifact.yaml
  install-checkov.sh     uninstall-checkov.sh
  install-checkov.ps1    uninstall-checkov.ps1
```

No parameters. Checkov takes its targets, frameworks and policies per invocation.

## Installation

Checkov is a Python tool, but the project ships it as a self-contained PyInstaller build,
so nothing here touches the node's Python: no interpreter, no `pip`, no virtualenv. The
download is a zip holding one 69 MB executable.

The binary goes to `/opt/checkov/<version>` on Linux, with `checkov` symlinked into
`/usr/local/bin`; the symlink is swapped atomically. On Windows it goes to
`%ProgramFiles%\checkov\<version>`, with a `current` junction and one machine PATH entry
pointing at the junction.

If the requested version is already on disk and runs, install repoints the symlink or
junction and stops there — the pool image is baked straight after this phase and every
node is then rebuilt from it, which runs install again on a disk that already has the
binary. At 69 MB a redundant download is worth avoiding.

### Verification

Checkov publishes **no checksums file**, unlike every other package here. GitHub reports a
SHA-256 of its own for each release asset, and that is what the download is checked
against.

This is weaker than the rest of the catalog, and the difference is worth stating plainly:
it is GitHub's hash of the file GitHub holds, not a signature by the publisher. It catches
a truncated or tampered download; it would not catch a compromised release. It is the only
integrity signal the project offers.

### Archive layout

The archive stores the binary as `dist/checkov`, and the Windows archive as
`dist//checkov.exe` — with a doubled separator, which is a malformed entry name. Neither
script extracts by path: the entry is taken by its file name. On Windows that also avoids
`Expand-Archive`, which would have to be trusted with that name.

## Versioning

`config.versions` is shaped after `java`, `node`, `go` and `snyk`: a JSON endpoint, a
`field` naming which value holds the version string, and a `pattern` whose named `version`
group extracts it. Without that named group the server has no version string to catalog
and only `default` appears.

Checkov tags carry **no** leading `v`, unlike most projects here, so the pattern expects a
bare `3.3.28` and the download URL uses it as is.

The list is one entry per minor. Selecting `default` installs the newest release.

## Platforms

Linux amd64 and Windows amd64 — two, not four. The project builds x86_64 only; there is no
arm64 asset for any platform. A macOS build exists but these nodes are Linux and Windows.

## Uninstall

Removes that version's tree. The exposure symlink, or the junction and its PATH entry, are
dropped only while they still point into this version's own tree — the runtime installs
the new version *before* running the superseded version's uninstall.

## Requirements

- Linux: root, `curl`, and `unzip` or `python3` to unpack. Windows: Administrator.
- Outbound HTTPS to `github.com` and `api.github.com`. The API is always consulted, for a
  pinned version as well as `default`, because the checksum lives there.

## Build

```bash
./orc build ./apps/checkov --output /tmp/checkov-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
CHECKOV_INSTALL_ROOT="$tmp/checkov" CHECKOV_BIN_DIR="$tmp/bin" APP_VERSION=3.3.28 \
  sh apps/checkov/install-checkov.sh
"$tmp/bin/checkov" --version
CHECKOV_INSTALL_ROOT="$tmp/checkov" CHECKOV_BIN_DIR="$tmp/bin" APP_VERSION=3.3.28 \
  sh apps/checkov/uninstall-checkov.sh
rm -rf "$tmp"
```
