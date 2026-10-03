# azure

Installs the Azure CLI and optionally signs it in as a service principal.

```text
azure/
  artifact.yaml
  install-azure.sh      start-azure.sh      uninstall-azure.sh
  install-azure.ps1     start-azure.ps1     uninstall-azure.ps1
  azure-common.ps1      # dot-sourced by the three Windows phases
```

Installation never receives or reads credentials. The start phase consumes
startup-lifetime credentials and signs the CLI in — the same division `aws` and
`gcloud` draw, and the one a pool bake requires: the install phase alone is what
gets snapshotted into the pool image, so an identity created there would be
shared by every clone.

## Parameters

- `azure_client_id` — optional service principal application (client) ID.
- `azure_client_secret` — optional sensitive client secret.
- `azure_tenant_id` — optional directory (tenant) ID.

Three fields, all optional, all needed together: that is simply what a service
principal is, and none of the three can be derived from the others. Omit all
three and the CLI is installed and left unauthenticated. Fill one in and the
other two become required — the start phase names whichever is missing, rather
than half-configuring the node.

The client ID is the application's GUID, not a person's sign-in name: an email
address belongs to a user account, and a service principal is not one. The
tenant may be either a GUID or a domain such as `contoso.onmicrosoft.com`.

Only the secret is marked sensitive; the client and tenant IDs are identifiers,
not secrets — the same line `jfrog` draws between `jfrog_url`, `jfrog_user` and
`jfrog_token`. Sensitive values are accepted from `AZURE_CLIENT_SECRET_FILE`, as
provided by ORC.

## The secret never reaches a command line

`az login --password @-` makes the CLI read the secret from standard input: the
`@` prefix is expanded by azure-cli-core before the arguments are parsed, and
`-` means stdin. Nothing sensitive appears in any process's command line, and
`/proc/<pid>/cmdline` is world readable to every job on the node.

At rest the secret does land in the CLI's own state, in
`service_principal_entries.json`, which the CLI writes mode 0600 but leaves
unencrypted on Linux — encryption there needs a session keyring, which a
headless node does not have. The start phase creates the state directory 0700
before signing in, because the CLI would otherwise create it 0755 and write its
profile world readable.

## Installation

Microsoft publishes no self-contained Linux archive. Their build pipeline
produces an MSI, a Windows zip, Docker images, Homebrew, RPM, DEB and a Python
wheel — nothing else. Of the routes that work on any distribution, pip into a
virtual environment is the one Microsoft supports (`az upgrade` knows it as the
`PIP` installer). Their `curl | bash` script reads from `/dev/tty` and so cannot
run unattended, and the apt and dnf repositories would add a Microsoft package
source to the node, which no app in this catalog does.

The CLI goes to `/opt/azure-cli/<version>`, one directory per version, and `az`
is symlinked into `/usr/local/bin`. `aws` keeps a single directory and replaces
it in place, which works only because `aws` ships no uninstall: the runtime
installs a new version *before* removing the superseded one, so with a shared
directory the old version's uninstall would delete the install that had just
replaced it. `go`, `java`, `node` and `terraform` are version-scoped for the
same reason.

A real file already at `/usr/local/bin/az` stops the install rather than being
overwritten, and a symlink pointing outside this app's root is left alone and
noted — an Azure CLI somebody else installed is not this app's to annex.

Debian and Ubuntu ship `python3` without the package that creates virtual
environments, and Alpine without the piece that seeds pip. Install fetches it
through apt-get, dnf, yum, zypper or apk — the same shape as `ensure_unzip` in
`aws`, `terraform` and `vault`.

## Versioning

`config.versions` reads the project's GitHub tags, the same source `aws` uses
and for the same reason: Azure/azure-cli tags every release but publishes no
GitHub releases. The tags carry a prefix which the pattern strips, so
`azure-cli-2.90.0` is offered as `2.90.0`, and that is what pip is given.

Selecting `default` installs the newest release: `APP_VERSION` arrives unset in
that case, and the install asks PyPI which release is current rather than
leaving it to pip — the directory is named after the version, so it has to be
known before the install rather than after. The installed version is then
checked against it and the install fails if they differ.

`python3` is checked for 3.10 or newer before anything is downloaded. Without
that check pip on an older interpreter quietly resolves to the last release that
still supported it — 2.66.2 on python3.8 — and the node would end up years
behind with nothing to show for it.

pip verifies every wheel against the hash PyPI publishes for it, so the download
is checked without this package fetching a checksum of its own.

## Uninstall

Removes that version's tree. If the `az` symlink pointed at it and this app is
what put it there, it moves to the newest version still installed, or goes away
when that was the last one. `aws` and `gcloud` ship no uninstall at all, but
they also predate the rule the versioned apps follow — an app that owns a
directory of its own removes it, the way `go`, `java`, `node` and `terraform`
do.

The CLI's sign-in state is deliberately left alone: it lives in the home
directory of whoever the start phase ran as, it may hold more than this app put
there, and it is not this app's to delete. Sign out with `az logout` if that
matters.

## Requirements

- **Linux:** root, and `python3` 3.10 or newer — that is what the Azure CLI
  requires. The version is checked before anything is downloaded.
- **Windows:** Administrator. The MSI is a per-machine install and brings its
  own Python, so nothing is required of the node's.
- **Outbound HTTPS** to PyPI and, on Windows, to Microsoft's installer host at
  install; to Microsoft's sign-in endpoints at start.

## Telemetry

The Azure CLI collects usage data by default. This package turns it off for the
commands it runs itself, and does not change it for the node's own use — that is
the node's decision. Set `AZURE_CORE_COLLECT_TELEMETRY=false` in the node's
environment, or run `az config set core.collect_telemetry=false`, to turn it off
for everything.

## Platforms

- Linux amd64 and arm64.
- Windows amd64. Microsoft builds the installer for x86 and x64 only; there is
  no arm64 MSI, and `aws` declares the same single Windows platform.

Windows takes a different route by necessity. There is no wheel install there:
Microsoft ships the CLI for Windows as an MSI that brings its own Python. The
versioned installer is
`azcliprod.blob.core.windows.net/msi/azure-cli-<version>-x64.msi` — the `-x64`
suffix is the 64-bit build and the unsuffixed name is the 32-bit one, which the
CLI's own upgrade code confirms and the published winget manifest corroborates
against the GUIDs in the installer's WiX source.

The MSI is per-machine, installs to `%ProgramFiles%\Microsoft SDKs\Azure\CLI2`
and **adds its own directory to the machine PATH**, removing it again on
uninstall. So unlike every other Windows app in this catalog there is no
junction to manage and no PATH entry to write.

Microsoft publishes no checksum or signature file beside the MSI, the way Amazon
does for its own — a real gap compared with the Linux half, where pip verifies
every wheel against PyPI's published hash. What the installer does carry is its
own Authenticode signature, so that is checked instead: an unsigned or altered
MSI is refused rather than run as administrator, and the signer is written to
the log.

## Limitations

- **A rotated secret is not picked up until the app is restarted.** The sign-in
  happens once, in the start phase. An expired or rotated client secret leaves
  the node signed in until the token expires and nothing renews it.
- **The sign-in state is never cleaned up.** Uninstall removes the CLI, not the
  credentials it wrote: those live in the home directory of whoever ran the
  start phase and may hold more than this app put there. Run `az logout` to
  clear them.
- **The secret is stored unencrypted at rest.** The CLI writes it to
  `service_principal_entries.json` mode 0600; encrypting that file needs a
  session keyring, which a headless node does not have.
- **Managed identity is not offered.** `az login --identity` needs no secret at
  all, but it only works on a node hosted in Azure, which these are not.
- **One version is exposed at a time.** On Linux several can be installed side
  by side, but `/usr/local/bin/az` points at one of them. On Windows only one
  can exist at all: the MSI replaces whatever was there.
- **A downgrade on Windows removes before it installs.** The MSI refuses to
  install over a newer product, so asking for an older version uninstalls the
  newer one first. There is a moment with no CLI on the node.

## Build

```bash
./orc build ./apps/azure --output /tmp/azure-oci
```

## Manual test

Run as root on Linux, or as Administrator on Windows — the install phase
requires it either way. The sign-in step is expected to fail without real
credentials. The Windows half installs per-machine and cannot be redirected to a
temporary directory, so test it on a node you are willing to change.

```bash
tmp=$(mktemp -d)
AZURE_CLI_INSTALL_DIR="$tmp/azure-cli" AZURE_CLI_BIN_DIR="$tmp/bin" APP_VERSION=2.90.0 \
  sh apps/azure/install-azure.sh

printf '%s' 'the-secret' >"$tmp/secret"
HOME="$tmp/home" \
AZURE_CLI_BIN_DIR="$tmp/bin" \
AZURE_CLIENT_ID=00000000-0000-0000-0000-000000000000 \
AZURE_CLIENT_SECRET_FILE="$tmp/secret" \
AZURE_TENANT_ID=00000000-0000-0000-0000-000000000000 \
  sh apps/azure/start-azure.sh

AZURE_CLI_INSTALL_DIR="$tmp/azure-cli" AZURE_CLI_BIN_DIR="$tmp/bin" APP_VERSION=2.90.0 \
  sh apps/azure/uninstall-azure.sh
rm -rf "$tmp"
```
