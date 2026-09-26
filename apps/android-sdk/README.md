# android-sdk

Installs the Android SDK command-line tools and accepts the SDK licences, so a
node can build Android projects.

## What it does, and what it deliberately does not

An Android build needs three things on a machine: the `sdkmanager` tool, the
accepted licences, and the SDK components the project pins — a platform, a
build-tools release, sometimes the NDK.

The first two need root, and neither depends on the project. This app installs
them, and stops there.

The components are the build's business. Gradle names them in the project's own
files and asks `sdkmanager` for whatever is missing, which lands in the same
shared tree and is there for the next build. Choosing them here would mean
guessing which `platforms;android-NN` every repository on the pool pins.

What the build *cannot* do is accept the licences: the prompt is interactive,
and the answers are written into a root-owned directory.

## Settings

None. There is nothing to configure.

## Layout

| Platform | Path |
|---|---|
| Linux | `/opt/android-sdk` |
| Windows | `%ProgramData%\android-sdk` |

Point the build at it:

```yaml
variables:
  ANDROID_HOME: /opt/android-sdk
```

`sdkmanager` itself lives at `cmdline-tools/latest/bin`, which is the layout it
insists on — the archive unpacks to a `cmdline-tools` directory whose contents
have to move one level down into `latest`.

The tools and the accepted licences stay owned by the installer and read-only to
everyone else — on Linux by ownership and mode, on Windows by switching
inheritance off on those two directories and granting `Users` read and execute
alone. Without that a build could replace `sdkmanager`, which the next install
phase runs with administrative rights.

The tree around them is opened so a build can install the components it pins: on
Linux mode `1777`, the same as `/tmp`, on Windows a `Users` modify grant. The
sticky bit stops a build removing the entries at that top level, including the
tools and the licences. It says nothing about what happens deeper: a component
directory belongs to whichever account created it, so **builds on a pool should
run under one account** — which is the normal arrangement, since the jobs on a
node run as the runner's service user.

**Setting `ANDROID_HOME` is the build's step, not ours.** The runtime does not
edit the environment of other processes, and a `profile.d` fragment would not be
read by a runner's non-login shell. A project that instead writes `sdk.dir` into
its `local.properties` works just as well.

## Versioning

No `versions` block, so the catalog offers a single `default`. Google publishes
no version list for the command-line tools: the build number is part of the
filename — `commandlinetools-linux-16111833_latest.zip` — and the only
machine-readable source is the repository index, which names exactly one current
build. There is nothing here for an operator to choose, and the version that
matters to a build is the component set it pins, not this.

## How the archive is found

The script reads `repository2-3.xml` from Google's SDK repository — the same
index `sdkmanager` itself uses — takes the archive whose `host-os` matches, and
verifies the download against the checksum published beside the URL.

Two consequences worth knowing:

- **The checksum is SHA-1.** That is what the machine-readable index publishes;
  the SHA-256 digests on the download page are HTML, not a source a script can
  read. SHA-1 is weak against a prepared collision, but it is checked against a
  digest fetched over HTTPS from the vendor at the same moment as the URL, which
  is the strongest guarantee the vendor offers.
- **Nothing is hard-coded.** The build number changes: Google's documentation
  page still showed `15859902` while the index already served `16111833`.

## Requirements

- **Linux x86-64 or Windows x64.** The command-line tools are Java and portable,
  but the components a build installs next — `adb`, `aapt2`, the build-tools —
  are published for x86-64 alone on Linux.
- **Administrative rights**, which lifecycle phases already have.
- **On Linux: `curl`, `unzip`, `python3`, `tar`, `awk`, `sed`, `find`,
  `sha1sum`, `sha256sum`.** All are present on a Debian or Ubuntu base image;
  `python3` reads the repository index and `unzip` opens the archive. The phase
  names whichever is missing and stops.
- **Outbound HTTPS** to `dl.google.com`, and — only when the node carries no
  usable Java — to `api.adoptium.net` and the host it redirects the download to,
  which today is `github.com` and `objects.githubusercontent.com`.

The app does not require the `java` app: `sdkmanager` is a Java program, so if
no `java` is found the install phase fetches a temporary JDK into a temporary
directory, verifies it against Adoptium's published checksum, uses it, and
deletes it with that directory. Picking this app alone is enough, and it does
not depend on the order two apps happen to install in.

**A build still needs a JDK of its own.** Gradle will not run without one — add
the `java` app, or use an image that carries one. That is outside this app's
scope, but it is the next thing that stops a build.

## Lifecycle

- **install** reads the repository index, verifies and unpacks the command-line
  tools, accepts every licence, and opens the tree for builds. Re-running
  replaces the tools and leaves the components a build installed in place.
- **uninstall** removes the whole SDK tree. It is entirely this app's — tools,
  licences and components alike — so it can go precisely, the same line `go`,
  `node` and `java` draw around their own trees.

## Limitations

- **The first build that needs a component still downloads it.** The shared tree
  removes the repeat, not the first one.
- **The tree is shared by every build on the node.** The build that installs a
  component first is the one whose binaries the others then run, and it owns
  that component's directory: a second build running as a different account
  cannot add to or replace it. On a pool running work from teams that do not
  trust each other, give each build its own `ANDROID_HOME` instead.
- **A failed install can leave a partial tree.** The phase creates
  `/opt/android-sdk` before it can know it will finish; a network failure
  part-way leaves the directory there, possibly with tools but without licences.
  Re-running the install repairs it — `uninstall` does not run after a failed
  `install`, so nothing cleans it up on its own.
- **Linux x86-64 and Windows x64 only.** macOS and arm64 are not covered.
- **Licences are accepted on the operator's behalf.** Adding this app to a pool
  means accepting Google's SDK terms for everything built there.
- **The install stops if Google ever publishes a different digest.** The script
  verifies the SHA-1 the index carries and refuses to proceed on anything else,
  rather than installing unverified. The day `repository2-3.xml` switches to
  SHA-256, this app needs a one-line change.
- **`ANDROID_SDK_INSTALL_ROOT` overrides the path** on both phases. Install with
  it set and uninstall without it and the tree is left behind, because the two
  phases would be looking at different directories.

## Build

```bash
./orc build ./apps/android-sdk --output /tmp/android-sdk-oci
```
