# codex

Installs OpenAI Codex CLI and optionally authenticates it with an OpenAI API key.

```text
codex/
  artifact.yaml
  install-codex.sh
  start-codex.sh
  install-codex.ps1
  start-codex.ps1
```

`artifact.yaml` explicitly selects the Unix or PowerShell lifecycle commands. The
install phase downloads an official Codex package, verifies its published SHA-256
checksum, and never reads the API key.

During start, ORC provides the startup-lifetime key through `OPENAI_API_KEY_FILE`.
The script sends it to the official `codex login --with-api-key` command over standard
input. Without a key, Codex remains ready for browser-based ChatGPT login.

## Parameter

- `openai_api_key` - optional sensitive OpenAI API key with `lifetime: startup`.

Codex stores successful authentication under `CODEX_HOME` (normally `~/.codex`).
Treat `auth.json` as a password and never commit or share it.

## Platforms

- Linux amd64 and arm64.
- macOS amd64 and arm64.
- Windows amd64 and arm64.

## Build

```bash
./orc build ./apps/codex --output /tmp/codex-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
CODEX_INSTALL_DIR="$tmp/bin" sh apps/codex/install-codex.sh
"$tmp/bin/codex" --version

printf '%s' test-key >"$tmp/key"
CODEX_HOME="$tmp/home" \
CODEX_INSTALL_DIR="$tmp/bin" \
OPENAI_API_KEY_FILE="$tmp/key" \
sh apps/codex/start-codex.sh

CODEX_HOME="$tmp/home" "$tmp/bin/codex" login status
rm -rf "$tmp"
```
