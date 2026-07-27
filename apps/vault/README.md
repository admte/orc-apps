# vault

Installs the HashiCorp Vault CLI and optionally authenticates it with the AppRole method.
The CLI is downloaded from HashiCorp Releases and verified against the published SHA-256
checksum.

```text
vault/
  artifact.yaml
  install-vault-unix.sh
  install-vault.ps1
  start-vault-unix.sh
  start-vault.ps1
```

## Parameters

- `vault_addr` - optional Vault server URL exposed to the CLI as `VAULT_ADDR`.
- `vault_role_id` - optional sensitive AppRole role ID.
- `vault_secret_id` - optional sensitive AppRole secret ID.

The role ID enables AppRole authentication. The secret ID is supplied when the selected
role requires one; a secret ID cannot be used without a role ID. All credential parameters
have `lifetime: startup`; the non-sensitive Vault address keeps the default runtime
lifetime. The install phase never reads any parameters. During the start phase, the
AppRole credentials are exchanged for a Vault token and the token is stored using the
Vault CLI token helper.

Sensitive values may be supplied directly or through `VAULT_ROLE_ID_FILE` and
`VAULT_SECRET_ID_FILE`.

## Platforms

- Linux: amd64 and arm64; installs to `/usr/local/bin` by default.
- macOS: amd64 and arm64; installs to `/usr/local/bin` by default.
- Windows: amd64; installs for the current user.

Set `VAULT_VERSION` to install a specific version instead of the latest release. Set
`VAULT_INSTALL_DIR` to override the installation directory.

Build + push (from the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`):

```bash
./orc build ./apps/vault --push
```

Validate locally without pushing (writes an OCI layout to disk):

```bash
./orc build ./apps/vault --output /tmp/vault-oci
```

Or pull the published artifact to verify its payload:

```bash
./orc pull vault:default /tmp/vault-pull
find /tmp/vault-pull -maxdepth 2 -type f -print
```

## Manual test

Install without using credentials:

```bash
sudo sh apps/vault/install-vault-unix.sh
vault version
```

Configure an AppRole login:

```bash
VAULT_ADDR=https://vault.example.com \
VAULT_ROLE_ID=role-id \
VAULT_SECRET_ID=secret-id \
sh apps/vault/start-vault-unix.sh
```

