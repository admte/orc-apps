# chocolatey

Windows-only app that installs the Chocolatey package manager and, optionally, the
packages an operator names.

```text
chocolatey/
  artifact.yaml
  install-chocolatey.ps1   # install the package manager, verified against its published SHA256
  start-chocolatey.ps1     # choco install <packages>
```

| Param | Description |
|-------|-------------|
| `packages` | Space-separated package names (e.g. `git 7zip curl`). Empty leaves the node with Chocolatey ready and nothing installed. |
| `chocolatey_source` | Package feed URL. Empty uses the Chocolatey Community Repository. |

`packages` is bare because `apt` already uses that exact name for that exact meaning.
`chocolatey_source` is prefixed for two reasons: it names a vendor concept, the way
`vault_addr` and `jfrog_url` do, and a bare `source` would reach the script as the
environment variable `SOURCE`, which is generic enough to collide with something else on
the node.

This is the Windows counterpart of `apt`, with one difference: `apt` is part of Debian
and Ubuntu, so that app only uses it, while Chocolatey is a third-party product that has
to be installed first. Hence two phases — install puts the manager on the node, start
installs packages with it.

## Installation

The vendor documents `irm https://community.chocolatey.org/install.ps1 | iex`. That
script verifies nothing it downloads: no checksum, no signature. Every other download in
this catalog is checked — `aws`, `terraform` and `vault` all compare a published SHA256 —
so this package takes the route the vendor documents for internal installs instead.

The project's GitHub release publishes a SHA256 for each of its artifacts in the release
notes. Install reads the release, downloads `chocolatey.<version>.nupkg`, compares the
hash, unpacks it — a `.nupkg` is an ordinary zip — and runs the
`tools\chocolateyInstall.ps1` it contains. That is the same installer the official
one-liner ends up running, reached without executing an unverified script.

Chocolatey installs itself to `C:\ProgramData\chocolatey`, adds that directory to the
machine PATH and restricts write access to administrators. So, unlike most Windows apps
in this catalog, there is no junction to manage and no PATH entry to write.

`.NET Framework 4.8` is required and is checked before anything is downloaded. The
vendor's script installs the framework itself when it is missing, which wants a restart —
and this phase runs while the pool image is being baked, so a node without 4.8 is refused
with a clear message instead of being left half-installed. Windows Server 2025 ships 4.8.1.

## Versioning

`config.versions` reads the project's GitHub releases. The tags are bare version numbers,
so `2.7.3` is offered as `2.7.3`.

Selecting `default` installs the newest release: `APP_VERSION` arrives unset in that
case, and install asks the project which release is current rather than guessing. The
installed version is then checked against what was requested, and the install fails if
they differ.

## No uninstall

Chocolatey keeps one shared directory and no versions side by side. The runtime installs
a new version *before* it runs the superseded version's uninstall, so an uninstall here
would delete the install that had just replaced it. `aws`, `apt`, `docker`, `uv` and
`cpp-dev-tools` ship no uninstall either, for the same or similar reasons.

To remove it by hand: delete `C:\ProgramData\chocolatey`, clear the `ChocolateyInstall`
machine variable and drop its `bin` directory from the machine PATH.

## The package feed

Chocolatey's terms of use reserve the Community Repository for individuals from
**1 January 2027**: organisations are expected to use their own repository, which may
cache the community one as an upstream source. JFrog Artifactory and Sonatype Nexus both
do this, and this catalog already ships a `jfrog` app.

Leaving `chocolatey_source` empty keeps using the public repository, which works today and
is noted in the node log on every start. Setting it to an internal feed is what the terms
will require. A feed that needs credentials is not supported yet — that will be an added
parameter when there is a feed to point it at, and adding one does not disturb pools that
do not use it.

## Requirements

- Windows amd64, Administrator, .NET Framework 4.8 or newer, PowerShell 5.1 or newer.
- Outbound HTTPS to `api.github.com` and `objects.githubusercontent.com` at install; to
  the package feed at start.

## Platforms

Windows amd64 only. Chocolatey is built for x64 Windows, and `aws` declares the same
single Windows platform.

Verified on Windows Server 2025 **Server Core**, where the app's phases run as
`NT AUTHORITY\SYSTEM`. Chocolatey has no MSIX component, so Server Core — which carries
no MSIX subsystem at all — is not an obstacle to it.

## Limitations

- **Packages are installed, never upgraded or removed.** Start runs `choco install`.
  A package already present is left at the version it has.
- **A package that asks for a restart does not get one.** Exit codes 1641 and 3010 are
  reported in the log and treated as success; the node is not restarted.
- **Not every package works on Server Core.** Packages that install desktop components
  will fail there. That is the package's property, not this app's.
- **One feed at a time.** `chocolatey_source` replaces the default rather than adding to
  it.
- **Install reads the GitHub API unauthenticated**, which allows 60 requests an hour per
  address. One bake makes one request, so this only matters if a great many pools bake
  from the same outbound address at once.

## Build

```bash
./orc build ./apps/chocolatey --output /tmp/chocolatey-oci
```

## Manual test

Run as Administrator on a Windows node; the install phase requires it. The install is
per-machine and cannot be redirected elsewhere, so test it on a node you are willing to
change.

```powershell
$env:APP_VERSION = '2.7.3'
powershell -NoProfile -ExecutionPolicy Bypass -File apps\chocolatey\install-chocolatey.ps1

$env:PACKAGES = 'git'
powershell -NoProfile -ExecutionPolicy Bypass -File apps\chocolatey\start-chocolatey.ps1
```
