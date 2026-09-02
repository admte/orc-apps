# node

Installs a selected Node.js release from the official distribution.

The app is install-only. ORC discovers `install-node` and `uninstall-node` by
their filenames, so no lifecycle commands are declared in `artifact.yaml`.

## Versioning

Versions come from <https://nodejs.org/dist/index.json>. Tags such as `v26.8.1`
are exposed as `26.8.1`, and the selected value arrives as `APP_VERSION`.

Each downloaded archive is verified against Node.js `SHASUMS256.txt`.

## Layout

- Linux: `/opt/node/<version>`, exposed through symlinks in `/usr/local/bin`.
- Windows: `%ProgramFiles%\node\<version>`, exposed through the `current`
  junction added to the machine `PATH`.

Installing another version repoints the exposure without deleting the older
version. Uninstall removes links only when they still point to that version.

## Platforms

- Linux amd64 and arm64.
- Windows amd64 and arm64.

## Build

```bash
./orc build ./apps/node --output /tmp/node-oci
```

After publishing `node:default`, inspect discovered versions with:

```bash
./orc versions node
```
