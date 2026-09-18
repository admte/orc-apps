# java

Installs a selected Eclipse Temurin JDK from Adoptium.

The app is install-only. ORC discovers `install-java` and `uninstall-java` by
their filenames.

## Versioning

Versions are discovered from
<https://api.adoptium.net/v3/info/release_versions>, the GA index Adoptium
publishes. Nothing is pinned in this repo: new Temurin releases appear without
a change here.

Adoptium's own version strings carry the build after a `+`
(`25.0.4+7.0.LTS`), which is not valid in an OCI tag. The filter therefore
exposes the release alone, so `25.0.4` arrives as `APP_VERSION`, and the
installer resolves the matching release name (`jdk-25.0.4+7`) through
`/v3/info/release_names` for the node's own OS and architecture. The version
range `[X,X.1)` covers every build of a release without reaching the next one.
Java 8 works the same way: `8.0.462` resolves to `jdk8u462-b08`.

The API window is a single page of the 50 newest GA versions, which currently
reaches back to Java 17; older lines are not offered. Because the filter keeps
`latest_per: minor`, each release line contributes its newest release, and the
newest discovered version is the default.

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

After publishing `java:default`, inspect discovered versions with:

```bash
./orc versions java
```
