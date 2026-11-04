# vault

Installs the HashiCorp Vault CLI so scripts and people on the machine can read secrets from
Vault. Give it a server address and AppRole credentials and the CLI is signed in at start; leave
them out and the CLI is installed ready for you to configure.

- `vault_addr` (optional): Vault server URL, e.g. `https://vault.example.com`
- `vault_role_id` (optional): AppRole role ID to sign in with
- `vault_secret_id` (optional): AppRole secret ID, for roles that require one; needs `vault_role_id`

Runs on Linux (amd64, arm64), macOS (amd64, arm64) and Windows (amd64).
