# osv-scanner

Version-scoped install of OSV-Scanner.

```text
osv-scanner/
  artifact.yaml
  install-osv-scanner.sh     uninstall-osv-scanner.sh
  install-osv-scanner.ps1    uninstall-osv-scanner.ps1
```

No parameters. OSV-Scanner is a command-line scanner: the install puts it on the PATH and
exits, and what it scans is decided by whoever runs it.

## Installation

The project publishes **bare executables** — `osv-scanner_linux_amd64`,
`osv-scanner_windows_amd64.exe` — so, as with `cosign`, `snyk` and `mise`, the plain binary
is taken and there is nothing to unpack. The architecture is part of the asset name.

Downloads are verified against `osv-scanner_SHA256SUMS`, one file covering every asset in
the release, the way `trivy` does it. `snyk`, by contrast, publishes a separate `.sha256`
per asset; both shapes appear in this catalog, which is why each package says which it
reads.

The binary goes to `/opt/osv-scanner/<version>` with `osv-scanner` symlinked into
`/usr/local/bin`, or to `%ProgramFiles%\osv-scanner\<version>` with a `current` junction
and a single machine PATH entry. Either way the exposure is swapped, never rewritten, so
switching versions does not touch the PATH.

If the requested version is already on disk and runs, install repoints the exposure and
stops there — the pool image is baked straight after this phase and every node is then
rebuilt from it, which runs install again on a disk that already has the binary.

## Versioning

`config.versions` uses the `json` source against the GitHub releases API rather than
`github_releases`: that source with a `filter.pattern` returns an empty version list on
the deployed server — tried on `cosign` and on `mise`, both times only `default` appeared —
and a pattern is needed here to strip the tag's leading `v`.

The `pattern` carries a named `version` group, which is what extracts the version from the
tag; without it the `v` would stay in the version string.

No `latest_per`. The project releases a few times a year, so the newest thirty releases
are already several years of history, and grouping by minor would hide patches rather than
tidy the list.

Selecting `default` installs the newest release.

## Platforms

Linux amd64 and arm64, Windows amd64 and arm64. The project publishes macOS builds too,
which no node here runs.

Windows arm64 is included because the project actually publishes that binary — `snyk`, for
instance, does not, which is why its manifest stops at amd64.

## Uninstall

Removes that version's tree. The exposure is dropped only while it still points into this
version's own tree — the runtime installs the new version *before* running the superseded
version's uninstall. On Windows the machine PATH entry goes only when the last version is
removed, since it points at the junction and stays correct for anything still installed.

## Logging

Progress goes to **stdout**, failures to stderr. The node log shows an install's stderr as
warnings, so a script that reports its progress there fills the log with `WRN` lines that a
healthy install has no business producing. The `vllm` app met this first and fixed it in
#43; the rest of this catalog still writes progress to stderr and will want the same
one-line change.

## Requirements

- Root (Linux) or the rights to write `%ProgramFiles%` and the machine PATH (Windows),
  and `curl`.
- Outbound HTTPS to `github.com` and, for the `default` tag, `api.github.com`.

## Build

```bash
./orc build ./apps/osv-scanner --output /tmp/osv-scanner-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
OSV_SCANNER_INSTALL_ROOT="$tmp/osv-scanner" OSV_SCANNER_BIN_DIR="$tmp/bin" \
  APP_VERSION=2.7.0 sh apps/osv-scanner/install-osv-scanner.sh
"$tmp/bin/osv-scanner" --version
OSV_SCANNER_INSTALL_ROOT="$tmp/osv-scanner" OSV_SCANNER_BIN_DIR="$tmp/bin" \
  APP_VERSION=2.7.0 sh apps/osv-scanner/uninstall-osv-scanner.sh
rm -rf "$tmp"
```
