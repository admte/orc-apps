# claude

Installs Claude Code and optionally configures an Anthropic API key.

```text
claude/
  artifact.yaml
  install-claude.sh
  start-claude.sh
  install-claude.ps1
  start-claude.ps1
```

`artifact.yaml` explicitly selects the Unix or PowerShell lifecycle commands. The install
phase never reads the API key. During start, ORC provides the startup-lifetime key through
`ANTHROPIC_API_KEY_FILE`; the script securely merges it into the `env` object in the
user-level Claude settings file. Claude Code reads that setting as `ANTHROPIC_API_KEY`.

Without a key, Claude Code remains ready for browser-based subscription login.

## Parameter

- `anthropic_api_key` - optional sensitive Anthropic API key with `lifetime: startup`.

Claude settings persist the configured key with owner-only permissions on Unix. Do not
commit the settings file or API key.

## Platforms

- Linux amd64 and arm64.
- macOS amd64 and arm64.
- Windows amd64 and arm64, Windows 10 1809+ or Windows Server 2019+.

The Windows installer checks the OS before reusing or downloading Claude Code. Windows
Server 2016 fails with an explicit upgrade message rather than a misleading download error.
See [Claude Code's system requirements](https://code.claude.com/docs/en/setup).

Windows downloads use native `curl.exe` with retries. Certificate trust and hostname
validation remain enabled; revocation fetches are skipped to tolerate fresh guests whose
network is still settling. If curl is unavailable or fails, PowerShell retries with TLS 1.2
enabled. Both paths retain the published archive's SHA-256 checksum verification.

## Build

```bash
./orc build ./apps/claude --output /tmp/claude-oci
```

## Manual test

```bash
tmp=$(mktemp -d)
CLAUDE_INSTALL_DIR="$tmp/bin" sh apps/claude/install-claude.sh
"$tmp/bin/claude" --version

printf '%s' test-key >"$tmp/key"
HOME="$tmp/home" \
CLAUDE_INSTALL_DIR="$tmp/bin" \
ANTHROPIC_API_KEY_FILE="$tmp/key" \
sh apps/claude/start-claude.sh

HOME="$tmp/home" "$tmp/bin/claude" doctor
rm -rf "$tmp"
```
