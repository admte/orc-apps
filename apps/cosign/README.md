# cosign

Version-scoped install of Sigstore cosign.

```text
cosign/
  artifact.yaml
  install-cosign.sh     uninstall-cosign.sh
  install-cosign.ps1    uninstall-cosign.ps1
```

No parameters. cosign takes its keys and policy per invocation.

## Installation

Sigstore publishes **bare executables**, not archives — `cosign-linux-amd64`,
`cosign-windows-amd64.exe` — so unlike `trivy`, `gitleaks`, `syft` and `k6` there is
nothing to unpack: the download is the binary.

It is verified against the release's `cosign_checksums.txt` before being put in place.
That file's name carries no version, unlike every other package here; it belongs to the
release and is fetched from the release's own download path.

The match is anchored on the whole file name, which matters more here than elsewhere:
each release also publishes `cosign-linux-amd64_<version>_linux_amd64.sbom.json` and
`cosign-linux-pivkey-pkcs11key-amd64`, both of whose names begin with the same text.

The binary goes to `/opt/cosign/<version>` on Linux, with `cosign` symlinked into
`/usr/local/bin`; the symlink is swapped atomically. On Windows it goes to
`%ProgramFiles%\cosign\<version>`, with a `current` junction and one machine PATH entry
pointing at the junction.

If the requested version is already on disk and runs, install repoints the symlink or
junction and stops there — the pool image is baked straight after this phase and every
node is then rebuilt from it, which runs install again on a disk that already has the
binary.

## Versioning

`config.versions` reads the project's GitHub releases, the same source `uv`, `terraform`
and `vault` use. The tags carry a leading `v`; the scripts accept the version written
either way and put the `v` back when building the download URL.

Selecting `default` installs the newest release.

## Platforms

Linux amd64 and arm64, Windows amd64. The project publishes no Windows arm64 binary.

Sigstore also ships `cosign-linux-pivkey-pkcs11key-amd64`, a build with hardware-token
support. This package installs the plain binary; the pivkey build is a different tool for
a different job and would be a package of its own.

## Uninstall

Removes that version's tree. The exposure symlink, or the junction and its PATH entry,
are dropped only while they still point into this version's own tree.

## Requirements

- Linux: root and `curl`. Windows: Administrator.
- Outbound HTTPS to `github.com` and, for the `default` tag, `api.github.com`.

## Build

```bash
./orc build ./apps/cosign --output /tmp/cosign-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
COSIGN_INSTALL_ROOT="$tmp/cosign" COSIGN_BIN_DIR="$tmp/bin" APP_VERSION=3.1.3 \
  sh apps/cosign/install-cosign.sh
"$tmp/bin/cosign" version
COSIGN_INSTALL_ROOT="$tmp/cosign" COSIGN_BIN_DIR="$tmp/bin" APP_VERSION=3.1.3 \
  sh apps/cosign/uninstall-cosign.sh
rm -rf "$tmp"
```
