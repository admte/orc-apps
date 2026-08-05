# jfrog

Installs JFrog CLI and configures a JFrog Platform server named `orc`.

```text
jfrog/
  artifact.yaml
  install-jfrog.sh
  start-jfrog.sh
  install-jfrog.ps1
  start-jfrog.ps1
```

`artifact.yaml` explicitly selects the Unix or PowerShell lifecycle commands. The install
phase never reads configuration or credentials. The start phase passes the access token to
JFrog CLI through standard input and stores the resulting CLI configuration.
JFrog CLI persists the token in its user configuration with owner-only file permissions,
like AWS CLI persists configured credentials.

## Parameters

- `jfrog_url` - required JFrog Platform base URL.
- `jfrog_user` - required JFrog username.
- `jfrog_token` - required sensitive access token with `lifetime: startup`.

ORC supplies the token through `JFROG_TOKEN_FILE`.

## Platforms

- Linux amd64 and arm64.
- macOS amd64 and arm64.
- Windows amd64.

## Build

```bash
./orc build ./apps/jfrog --output /tmp/jfrog-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
JFROG_CLI_INSTALL_DIR="$tmp/bin" sh apps/jfrog/install-jfrog.sh

printf '%s' test-token >"$tmp/token"
JFROG_CLI_INSTALL_DIR="$tmp/bin" \
JFROG_CLI_HOME_DIR="$tmp/home" \
JFROG_URL=https://example.jfrog.io \
JFROG_USER=test-user \
JFROG_TOKEN_FILE="$tmp/token" \
sh apps/jfrog/start-jfrog.sh

JFROG_CLI_HOME_DIR="$tmp/home" "$tmp/bin/jf" config show orc
rm -rf "$tmp"
```
