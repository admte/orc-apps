# cursor

Installs Cursor CLI and starts its terminal agent with an optional Cursor API key.

```text
cursor/
  artifact.yaml
  install-cursor.sh
  start-cursor.sh
  install-cursor.ps1
  start-cursor.ps1
```

`artifact.yaml` explicitly selects the Unix or PowerShell lifecycle commands. The
install phase runs Cursor's official platform installer and never reads the API key.

During start, ORC provides the startup-lifetime key through `CURSOR_API_KEY_FILE`.
The script reads it, exports `CURSOR_API_KEY` only to the Cursor Agent process, and
does not persist the key on disk. Without a key, the agent supports browser login.
Because the start phase runs the interactive agent, `orc start` remains attached
until the agent exits.

## Parameter

- `cursor_api_key` - optional sensitive Cursor API key with `lifetime: startup`.

Create API keys at <https://cursor.com/dashboard/api>. API-key usage may be billed
separately from an interactive Cursor subscription.

## Platforms

- Linux amd64 and arm64.
- macOS amd64 and arm64.
- Windows amd64 and arm64.

## Build

```bash
./orc build ./apps/cursor --output /tmp/cursor-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
HOME="$tmp/home" sh apps/cursor/install-cursor.sh
"$tmp/home/.local/bin/agent" --version

HOME="$tmp/home" sh apps/cursor/start-cursor.sh
rm -rf "$tmp"
```

To test API-key authentication, pass a real key through ORC:

```bash
./orc start cursor:default --cursor-api-key @/path/to/cursor-api-key
```
