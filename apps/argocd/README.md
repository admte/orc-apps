# argocd

Version-scoped install of the Argo CD command-line client.

```text
argocd/
  artifact.yaml
  install-argocd.sh     uninstall-argocd.sh
  install-argocd.ps1    uninstall-argocd.ps1
```

No parameters. `argocd` is a client: which Argo CD it talks to is decided by whoever runs
it, with `argocd login`.

**The CLI, not the server.** An Argo CD release carries both. The server is a set of
Kubernetes controllers and is not something a node installs; the `argocd-*` assets in the
release are the command-line client, and those are what this package takes.

## Installation

The project publishes **bare executables** — `argocd-linux-amd64`,
`argocd-windows-amd64.exe` — so, as with `cosign`, `snyk` and `osv-scanner`, the plain
binary is taken and there is nothing to unpack. The architecture is part of the asset name.

Downloads are verified against `cli_checksums.txt`, one file covering every asset in the
release, the way `trivy` and `osv-scanner` do it. The match is on the whole file name: the
checksum file lists darwin, ppc64le and s390x builds too, so a prefix match would be
ambiguous the day a suffixed variant appears.

The binary goes to `/opt/argocd/<version>` with `argocd` symlinked into `/usr/local/bin`,
or to `%ProgramFiles%\argocd\<version>` with a `current` junction and a single machine
PATH entry. Either way the exposure is swapped, never rewritten, so switching versions
does not touch the PATH.

If the requested version is already on disk and runs, install repoints the exposure and
stops there — the pool image is baked straight after this phase and every node is then
rebuilt from it, which runs install again on a disk that already has the binary.

## Versioning

`config.versions` uses the `json` source against the GitHub releases API rather than
`github_releases`: that source with a `filter.pattern` returns an empty version list on
the deployed server — tried on `cosign` and on `mise`, both times only `default` appeared —
and a pattern is needed here.

The `pattern` carries a named `version` group, which extracts the version from the tag;
without it the leading `v` would stay in the version string. Requiring three plain numbers
also keeps the release candidates (`v3.5.6-rc1`) out of the list.

`latest_per: minor` gives one entry per minor line — its newest patch. The project
maintains several lines at once and patches them in parallel, so that is the useful view.

Selecting `default` installs the newest release.

## Platforms

Linux amd64 and arm64, Windows amd64.

The release also carries Linux ppc64le and s390x, which no node here runs, and macOS
builds. There is no Windows arm64 build at all — `install-argocd.ps1` says so outright on
an arm64 node rather than reaching for an asset that does not exist.

## Uninstall

Removes that version's tree. The exposure is dropped only while it still points into this
version's own tree — the runtime installs the new version *before* running the superseded
version's uninstall. On Windows the machine PATH entry goes only when the last version is
removed, since it points at the junction and stays correct for anything still installed.

## Logging

Progress goes to **stdout**, failures to stderr. The node log shows an install's stderr as
warnings, so a script that reports its progress there fills the log with `WRN` lines that a
healthy install has no business producing. The `vllm` app met this first and fixed it in
#43.

## Requirements

- Root (Linux) or the rights to write `%ProgramFiles%` and the machine PATH (Windows),
  and `curl`.
- Outbound HTTPS to `github.com` and, for the `default` tag, `api.github.com`.

## Build

```bash
./orc build ./apps/argocd --output /tmp/argocd-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
ARGOCD_INSTALL_ROOT="$tmp/argocd" ARGOCD_BIN_DIR="$tmp/bin" \
  APP_VERSION=3.5.6 sh apps/argocd/install-argocd.sh
"$tmp/bin/argocd" version --client
ARGOCD_INSTALL_ROOT="$tmp/argocd" ARGOCD_BIN_DIR="$tmp/bin" \
  APP_VERSION=3.5.6 sh apps/argocd/uninstall-argocd.sh
rm -rf "$tmp"
```

`version --client` rather than `version`: the plain form tries to reach a server and fails
when none is configured.
