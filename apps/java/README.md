# java

Installs a selected Eclipse Temurin JDK from Adoptium.

The app is install-only. ORC discovers `install-java` and `uninstall-java` by
their filenames.

## Versioning

Adoptium release names contain `+`, which is not valid in an OCI tag. The fixed
version list therefore replaces `+` with `_`: `21.0.12_8` maps exactly to the
upstream release `jdk-21.0.12+8`. Java 8 keeps its upstream form, for example
`8u502-b07`.

The default is the tested Temurin 25 LTS release. Updating the offered list
requires adding a concrete Adoptium GA release after verifying it exists on all
declared platforms.

The installer uses Adoptium's exact-version binary and checksum endpoints and
fails if the SHA-256 does not match.

## Layout

- Linux: `/opt/java/<version>`, with JDK commands symlinked into
  `/usr/local/bin` and `/opt/java/current` pointing to the active version.
- Windows: `%ProgramFiles%\java\<version>`, exposed through a `current`
  junction. Its `bin` directory is added to the machine `PATH`, and
  machine-level `JAVA_HOME` points to `current`.

Installing another version repoints the exposure while retaining the older
tree. Uninstall removes links only when they still belong to that version.

## Platforms

- Linux amd64 and arm64.
- Windows amd64. Adoptium does not publish Windows arm64 builds for every
  offered JDK release.

## Build

```bash
./orc build ./apps/java --output /tmp/java-oci
```
