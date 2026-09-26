# playwright

Installs the system libraries that Playwright's browsers link against, so a node
can run Playwright tests.

## What it does, and what it deliberately does not

A Playwright run needs three things on a machine: the system dependencies, the
`playwright` package, and the browser builds themselves.

Only the first needs root, and only the first is the same for every Playwright
release. This app installs that, and nothing else.

What "system dependencies" means differs by platform, and Playwright's own
`install-deps` command knows both:

- **Linux** — several dozen packages the browsers link against: fonts, `libnss`,
  `libatk`, GStreamer, mesa.
- **Windows** — the Media Feature Pack, which Chromium's codecs need and which
  Windows Server and the N and KN editions ship without. Everything else comes
  with the browser builds.

The other two belong to the job. A repository pins its own Playwright version in
`package.json`, and the browser builds are matched to that exact version — a
build downloaded here for 1.56 is not the build a repository pinned to 1.49 will
run. So the job keeps doing what it already does:

```bash
npm ci
npx playwright install
npx playwright test
```

What the job *cannot* do is `apt-get install` as root. Without this app that is
where a Playwright run on a fresh node stops, with `Host system is missing
dependencies` — the runner's service account has no way to fix it.

## The shared browser cache

The app also creates a directory the jobs can share:

| Platform | Path |
|---|---|
| Linux | `/usr/local/share/ms-playwright` |
| Windows | `%ProgramData%\ms-playwright` |

Point the job at it and the browsers of a given Playwright version are
downloaded once on the node instead of once per job:

```yaml
variables:
  PLAYWRIGHT_BROWSERS_PATH: /usr/local/share/ms-playwright
```

Nothing is put there at install time, and no version is chosen: Playwright keeps
each version's builds in its own subdirectory, so the first job of a version
fills it and every later job of that version reads it. A job on a different
version simply adds its own.

On Linux the directory carries mode `1777`, the same as `/tmp`: any job may add
a version, and the sticky bit stops it removing a directory another job created.
On Windows the `Users` group is granted modify rights on that folder.

**Setting the variable is the job's step, not ours.** The runtime does not edit
the environment of other processes, and a `profile.d` fragment would not be read
by a runner's non-login shell. Without that one line the app still works — the
job just downloads browsers every time.

## Settings

None. There is nothing to configure.

## Versioning

No `versions` block, so the catalog offers a single `default`. Two reasons:

- The library list does not meaningfully vary between Playwright releases.
- The release that matters is the one pinned in the repository under test, and
  that is not known when a node is requested. Offering a version picker here
  would ask the operator a question they cannot answer, and a wrong answer would
  fail silently — the job would simply download everything again.

## How the list is obtained

The script does not carry a package list. It runs `npx playwright install-deps`,
which is Playwright's own command for this and is kept current with each
release, per distribution. A list copied into this repository would rot without
anyone noticing.

`npx` fetches the package from the npm registry, which verifies the published
integrity digest before anything runs. The temporary Node.js, when one is
needed, is verified against `SHASUMS256.txt` from the same directory it was
downloaded from, and the phase fails on a mismatch.

## Requirements

- **Debian 12/13 or Ubuntu 22.04/24.04/26.04** on x86-64 or arm64, or **Windows
  on x64**. These are the platforms Playwright supports, and the only ones
  `install-deps` knows. The install phase fails loudly on anything else rather
  than half-preparing a node — Playwright itself would warn and try apt anyway,
  which on a node without apt is a slow way to fail.
- **Administrative rights**, which lifecycle phases already have.
- **Outbound HTTPS** to the npm registry, and to `nodejs.org` when the node
  carries no Node.js of its own.

Nothing else. In particular the app does **not** require the `node` app: if
`npx` is missing it fetches a Node.js of its own into a temporary directory,
verifies it against the checksums the project publishes, uses it to run
Playwright's installer, and deletes it with the rest of the temporary directory.
Picking this app alone, on one screen, is enough — which also avoids depending
on the order two apps happen to install in.

## Lifecycle

- **install** checks the platform, makes sure a Node.js is available, installs
  the dependencies through Playwright, and creates the shared cache directory.
  Re-running is harmless: `apt-get install` on packages that are already present
  is a no-op, so is the Media Feature Pack installer, and the cache directory is
  only created if missing.

There is no `uninstall`. These are shared system libraries, and several of them
were probably on the node before this app arrived; removing them would break
whatever else links against them.

## Limitations

- **The first job of each Playwright version still downloads its browsers.**
  The cache removes the repeat, not the first one. Pre-seeding would mean
  choosing a version here, and the version that is right is the one each
  repository pins — which is not knowable when a node is requested.
- **The cache is shared by every job on the node.** The sticky bit stops one job
  deleting another's browsers, but the job that downloads a version first is the
  one whose binaries the others then execute. On a pool running work from teams
  that do not trust each other, leave `PLAYWRIGHT_BROWSERS_PATH` unset and let
  each job use its own cache.
- **Debian, Ubuntu and Windows x64 only.** Playwright publishes its dependency
  lists for those; on RHEL, Alpine, SUSE, macOS or Windows arm64 the install
  phase fails rather than guessing.
- **Windows does far less work than Linux,** because the browser builds there
  carry their own libraries. On an ordinary Windows 11 image the Media Feature
  Pack is usually present already and the phase is close to a no-op — it earns
  its place on Windows Server and on N editions.
- **The library list comes from whatever Playwright release `npx` resolves at
  install time.** That is the intent — it is how the list stays current — but it
  means two nodes built months apart can differ slightly.

## Build

```bash
./orc build ./apps/playwright --output /tmp/playwright-oci
```
