# dotnet

Installs a selected .NET SDK from Microsoft's published archives.

The app is install-only. ORC discovers `install-dotnet` and `uninstall-dotnet`
by their filenames. There are no parameters: the version is the only choice, and
it is made from the version list.

## Versioning

Versions come from Microsoft's release index,
<https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json>,
which publishes one entry per .NET release band together with that band's newest
SDK. The list is therefore the newest SDK of every band — `9.0.318`, `8.0.425`
and so on — with the preview bands, whose versions carry a suffix, excluded.

The filter starts at .NET 5. That is the first release with archives for every
platform declared below: the 3.1, 3.0, 2.2 and 2.1 bands publish no Windows
arm64 SDK, and the 1.x bands name their archives differently again
(`dotnet-dev-ubuntu-x64.1.1.14.tar.gz`). `go` draws the same line at 1.17 for
the same reason.

**An older patch inside a band cannot be selected**, and that is a limitation of
the source rather than a choice: Microsoft publishes no endpoint that lists every
SDK version. The full versions exist only inside the per-band `releases.json`
files, nested two levels deep, out of reach of a single pointer. What the list
does offer is the same thing `go` and `java` offer — the newest build of each
line.

The installer starts from that same index. It asks which band publishes the
chosen version rather than deriving it from the number, because the number does
not always say: `2.1.202` is published under band `2.0`. From the band's own
`releases.json` it takes the download URL and the **SHA-512** for exactly this
node's platform, and refuses to install anything whose checksum does not match.

Alpine and other musl systems get the `linux-musl` build. The glibc archive
would extract cleanly there and then fail to run at all, so the libc is detected
the way Microsoft's own `dotnet-install.sh` detects it.

## When no version is chosen

The version list offers `default` first, and it is what the request form starts
on. A request that resolves to that tag reaches the scripts with `APP_VERSION`
**unset** — the contract says so in as many words, so that an omitted version
still looks omitted inside a lifecycle script.

Install treats that as the ordinary case rather than an error: it takes the
newest SDK the index offers, narrowed exactly as the version list is narrowed,
and says in the log which one it picked. Uninstall does not repeat that
calculation — a newer patch may have been published since, and that one was
never installed here — it reads what install recorded in the marker.

The other version-scoped apps in this catalog (`go`, `java`, `node`) fail on
`default` instead, because they require `APP_VERSION`. That is worth fixing
there too; it is not fixed by this package.

## Layout: one shared root, not one directory per version

This app deliberately departs from `go`, `java` and `node`, which give every
version its own tree and expose one of them.

.NET is built the other way round. The archive is already laid out by version
inside — `sdk/<version>`, `shared/Microsoft.NETCore.App/<version>`,
`host/fxr/<version>` — and Microsoft's documentation states that "different
versions of .NET can be extracted to the same folder, which coexist
side-by-side". Nothing collides, because nothing shares a path.

Giving each version its own root would produce two installations that cannot see
each other. The `dotnet` executable resolves everything next to itself, and the
`DOTNET_ROOT` variable does not change that — it applies to published
applications, not to the SDK's own lookup. So `dotnet --list-sdks` would report
one version, and a project whose `global.json` pins another would fail to build:
the default policy is to use the pinned version, roll forward to a newer patch
of the same band, and otherwise fail.

- **Linux:** `/opt/dotnet`, with `dotnet` symlinked into `/usr/local/bin`. The
  symlink is safe here — the host resolves its own path with `realpath` before
  looking for anything beside it, which its source says in as many words. The
  executable may be linked but not renamed: it refuses to run under another
  name. If a symlink is already there it is repointed, with a line in the log
  saying what it used to be; if a real file is there, install stops rather than
  destroy something it cannot put back.
- **Windows:** `%ProgramFiles%\dotnet`, added to the machine `PATH`. No `current`
  junction: junctions exist to expose one version of a per-version tree, and
  this root exposes every installed version at once.

Installing a second version adds it beside the first, and both appear in
`dotnet --list-sdks`.

Applications published as native executables find their runtime through
`DOTNET_ROOT`, not through the SDK. On Windows the root above is also the
default probe path, so nothing is needed. On Linux `/opt/dotnet` is not a probe
path, so a node that runs published apphost binaries needs `DOTNET_ROOT` set to
it in the environment; running them with `dotnet <app>.dll` needs nothing.

## Uninstall

Only `sdk/<version>` is removed — exactly what this app added. The shared
runtimes beside it are left, because two SDK bands of one release carry the same
runtime and removing it would break the SDK that is still installed. Microsoft
documents removing these versioned directories by hand and warns that their
version numbers differ from the SDK's.

The root and the command in the path go only if this app is what put them there.
Install records both facts in `.orc-dotnet-install` inside the root, before
anything can fail, so an install interrupted halfway is still removable. On a
node whose .NET predates the app, the root stays, the node's own `PATH` entry
stays, and the record itself is removed rather than left behind in someone
else's installation.

## Requirements

- **Root**, plus `curl`, `tar` and `sha512sum` on Linux.
- **ICU.** The SDK does not start on Linux without it. Rather than guess whether
  the library is present, install runs the SDK and looks at how it fails: only a
  globalization complaint gets ICU installed, through apt-get, dnf, yum, zypper
  or apk, after which the SDK is run again. Any other failure is reported as it
  happened, without rearranging the node's packages. On Debian and Ubuntu the
  package name carries a version that differs per release, so it is looked up
  rather than hard-coded; on Alpine both `icu-libs` and `icu-data-full` are
  needed.
- **Disk.** The SDK archive is a few hundred megabytes, and each additional
  version adds its own.

## Telemetry

The .NET SDK sends usage data to Microsoft by default. This package does not
change that for the node's own builds — that is the node's decision — but it
does turn it off for the one command it runs itself to verify the install. To
turn it off for everything, set `DOTNET_CLI_TELEMETRY_OPTOUT=1` in the node's
environment; `DOTNET_NOLOGO=1` silences the first-run banner separately and does
not affect telemetry.

## Platforms

- Linux amd64 and arm64, glibc or musl.
- Windows amd64 and arm64.

## Build

```bash
./orc build ./apps/dotnet --output /tmp/dotnet-oci
```

After publishing `dotnet:default`, inspect discovered versions with:

```bash
./orc versions dotnet
```
