# mise

Version-scoped install of mise.

```text
mise/
  artifact.yaml
  install-mise.sh     uninstall-mise.sh
```

No parameters. mise reads its tool versions from the project it is run in.

## Installation

mise publishes **bare executables** beside its archives — `mise-v<version>-linux-x64` — so,
as with `cosign` and `snyk`, the plain binary is taken and there is nothing to unpack. The
archives hold the same binary plus shell completions, which the node has no use for.

The version is part of the asset name, as with `k6`.

Downloads are verified against the release's `SHASUMS256.txt`. The names in that file
carry a `./` prefix, which the script allows for; the match is still on the whole name,
which matters because `mise-v<version>-linux-x64` is a prefix of its `-musl` sibling and
of every archive of the same build.

The binary goes to `/opt/mise/<version>`, with `mise` symlinked into `/usr/local/bin`; the
symlink is swapped atomically.

If the requested version is already on disk and runs, install repoints the symlink and
stops there — the pool image is baked straight after this phase and every node is then
rebuilt from it, which runs install again on a disk that already has the binary.

## Versioning

`config.versions` uses the `json` source against the GitHub releases API, as `snyk` does,
rather than the purpose-built `github_releases` source.

That looks like the long way round, and spec 142 describes `github_releases` with a
`filter.pattern` at length — but the deployed server returns an empty version list for
that combination. It was tried here and on `cosign`; both times only `default` appeared.
`github_releases` *without* a pattern does work, as `trivy` shows. A pattern is needed here
to strip the tag's leading `v`, so the `json` source is the one that fits.

The `pattern` carries a named `version` group, which is what extracts the version from the
tag: a pattern without that group only filters, and the tag's leading `v` would stay in
the version string.

mise uses a calendar version, so the three components are year, month and a counter rather
than major, minor and patch. `latest_per: minor` would therefore mean "one per month",
which is not a useful grouping, so the list is simply the newest thirty releases.

Selecting `default` installs the newest release.

## Platforms

**Linux amd64 and arm64 only**, although the project publishes Windows binaries too.

mise is Rust built against the MSVC toolchain, so `mise.exe` needs `vcruntime140.dll` and
`msvcp140.dll`. Those ship with the Visual C++ Redistributable, not with Windows, and a
Server Core node has neither: `dir C:\Windows\System32\vcruntime140.dll` answers
`File Not Found`. The binary then exits `0xC0000135` (`STATUS_DLL_NOT_FOUND`) before
reaching `main`, printing nothing at all — the loader fails first.

This is why the rest of the catalog is unaffected: `trivy`, `syft`, `k6`, `cosign` and
`snyk` are Go, which needs no MSVC runtime, and `checkov` is a PyInstaller build that
carries its own.

Installing the redistributable from the install script was considered and rejected. It is
a system component: it would outlive this app's uninstall, change the node for everything
else on it, and add a download from Microsoft to every install. No other package here
changes a node that way. If these nodes ever carry the runtime, re-adding Windows is two
entries under `platforms` and the two PowerShell scripts, which git still has.

The project also builds musl variants of the Linux binaries. These nodes are glibc, so
those are never the right assets; the script takes the plain ones.

## Uninstall

Removes that version's tree. The exposure symlink is dropped only while it still points
into this version's own tree — the runtime installs the new version *before* running the
superseded version's uninstall.

mise keeps the tools it manages outside this tree, under the user's own data directory.
Uninstalling the package removes mise, not what mise installed.

## Requirements

- Root and `curl`.
- Outbound HTTPS to `github.com` and, for the `default` tag, `api.github.com`.

## Build

```bash
./orc build ./apps/mise --output /tmp/mise-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
MISE_INSTALL_ROOT="$tmp/mise" MISE_BIN_DIR="$tmp/bin" APP_VERSION=2026.10.10 \
  sh apps/mise/install-mise.sh
"$tmp/bin/mise" --version
MISE_INSTALL_ROOT="$tmp/mise" MISE_BIN_DIR="$tmp/bin" APP_VERSION=2026.10.10 \
  sh apps/mise/uninstall-mise.sh
rm -rf "$tmp"
```
