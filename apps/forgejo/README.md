# forgejo

Forgejo, a self-hosted Git service, run as a managed service.

```text
forgejo/
  artifact.yaml
  install-forgejo.sh    start-forgejo.sh    uninstall-forgejo.sh
```

No parameters. Forgejo's own first-run setup page chooses the database and creates the
first administrator; see [First run](#first-run).

This is the first **server** in this catalog. Everything before it was a command-line tool
that installs and exits; this one holds data, listens on a port, and runs as a service.

## Installation

Forgejo publishes **bare executables** — `forgejo-<version>-linux-amd64` — so, as with
`cosign`, `snyk` and `mise`, the plain binary is taken and there is nothing to unpack.
Each binary carries its own `.sha256` beside it, as `snyk` does.

The binary goes to `/opt/forgejo/<version>`, with `forgejo` symlinked into
`/usr/local/bin`; the symlink is swapped atomically. The service resolves its binary
through that symlink on every restart, so switching versions needs no change to the
service definition.

Install also creates the `forgejo` system account and the data directory. It creates
**nothing inside** that directory beyond permissions — see below.

## Data

`config.persist` declares `/var/lib/forgejo`. The platform grafts that path onto the
node's App-data volume before install runs, and keeps it across the life of the node.
Everything Forgejo owns lives under it: repositories, the SQLite database, and the
`app.ini` its setup page writes.

That single root is deliberate — one path to declare, one thing to restore.

**The uninstall never touches it.** The app contract is explicit that an uninstall must
not delete a declared persisted path, and here the reason is concrete: uninstall runs when
a version is *superseded*, so deleting the data would destroy every repository on the node
the moment someone switched versions.

### Two things a persisted path does not do

Both of these cost a failed node each to find, and neither is in spec 142. Any app that
declares `persist` will meet them.

**Install cannot shape the tree.** Install runs while the pool image is baked, so
directories it creates under a persisted path land on the OS disk — and the platform then
mounts its volume over that path. A node rebuilt from the image finds the tree as the
volume has it (`App data restored: 0 files` on a first run), and an unprivileged server
cannot create the first directory itself. Forgejo's first attempt died on
`mkdir /var/lib/forgejo/custom: permission denied`.

**A restore does not return ownership.** The files come back, but not necessarily owned by
the account the app runs as. The second attempt restored `app.ini` correctly and then died
on `open …/app.ini: permission denied`.

Hence `ensure_layout` in `start-forgejo.sh`: it runs on every boot, after the volume is in
place and while still root, creates the directories and applies ownership **recursively**.
It changes no modes and creates or removes nothing inside, so a restored instance keeps
its content exactly as it was. Install keeps a copy of the same call, which only matters
when there is no persisted volume behind the path — the manual test, for instance.

## First run

Forgejo with no `app.ini` serves its setup page: it asks for the database and the first
administrator account, then writes the configuration and locks the installer.

This package deliberately does **not** do that for you. Creating the administrator from a
script means `forgejo admin user create --password …`, and a password in a process's
arguments is readable by anything running on the node through `/proc/<pid>/cmdline`. Not
automating it keeps secrets out of this package entirely.

The practical consequence: between first start and completed setup, anyone who can reach
port 3000 can claim the instance. Complete the setup before the endpoint is reachable by
anyone else.

Because the data directory is persisted, this happens **once** — a node rebuilt from the
baked pool image finds a configured instance and starts straight into it. Install reports
which case it saw, from `APP_PERSIST_STATE`.

## Service

`start.service: forgejo` with `restart: always`. The node writes the service definition
itself; this package ships no unit file and enables nothing for boot.

`start-forgejo.sh` drops to the `forgejo` account with `setpriv` — never `su` or `runuser`
— inside the same session, and execs the server, so the service's main pid is Forgejo
itself and the stop signal reaches it. The idiom is `jenkins-agent`'s.

Forgejo closes its listeners and finishes in-flight requests on SIGTERM, so there is
nothing to drain and no stop command: `stop` declares only the bounds, 60s then a 30s
grace.

## Endpoints

One: `web` on port 3000, `protocol: http`, probed at `/api/healthz`.

`serve: primary` — one instance owns the data, so slot 1 alone answers and is fenced while
unfit. A second member serving the same repositories would corrupt them.

Forgejo's built-in SSH server is not declared. It is off until the setup page or `app.ini`
turns it on, and port 22 belongs to the node.

## Platforms

Linux amd64 and arm64. The project publishes no Windows or macOS binaries.

## Versioning

Forgejo is hosted on Codeberg, not GitHub, so neither `github_*` source applies. Codeberg
runs Forgejo itself and serves a Gitea-compatible API, which the `json` source reads — the
same source `snyk` and `mise` use.

The `pattern` carries a named `version` group, which is what extracts the version from the
tag; without it the tag's leading `v` would stay in the version string.

## Requirements

- Root, `curl`, `useradd` and `setpriv`.
- Outbound HTTPS to `codeberg.org`.

## Build

```bash
./orc build ./apps/forgejo --output /tmp/forgejo-oci
```

## Manual test

The install phase alone, without the service:

```bash
tmp=$(mktemp -d)
sudo FORGEJO_INSTALL_ROOT="$tmp/forgejo" FORGEJO_BIN_DIR="$tmp/bin" \
  FORGEJO_DATA_DIR="$tmp/data" APP_VERSION=16.0.6 \
  sh apps/forgejo/install-forgejo.sh
"$tmp/bin/forgejo" --version
```

It creates the `forgejo` account, so it needs root even with the paths redirected.
