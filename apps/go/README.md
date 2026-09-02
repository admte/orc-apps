# go

Installs a selected Go toolchain from the official Go distribution.

The app is install-only. ORC discovers `install-go` and `uninstall-go` by their
filenames.

## Versioning

Versions and checksums come from <https://go.dev/dl/?mode=json&include=all>.
Values such as `go1.27.0` are exposed as `1.27.0`, and the selected value arrives
as `APP_VERSION`. The version pattern excludes releases older than Go 1.17 so
every offered version has archives for all declared platforms, including
Windows arm64.

The installer selects the archive for the node's platform and verifies the
published SHA-256 before extraction.

## Layout

- Linux: `/opt/go/<version>`, with `go` and `gofmt` symlinked into
  `/usr/local/bin`.
- Windows: `%ProgramFiles%\go\<version>`, exposed through a `current` junction
  whose `bin` directory is on the machine `PATH`.

Installing another version repoints the exposure while retaining the older
tree. Uninstall removes the exposure only when it still belongs to that version.

## Platforms

- Linux amd64 and arm64.
- Windows amd64 and arm64.

## Build

```bash
./orc build ./apps/go --output /tmp/go-oci
```
