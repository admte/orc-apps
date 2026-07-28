# aws

Installs AWS CLI v2 and optionally configures the default credentials profile.

```text
aws/
  artifact.yaml
  install-aws.sh
  start-aws.sh
  install-aws.ps1
  start-aws.ps1
```

`artifact.yaml` explicitly selects the Unix or PowerShell lifecycle commands for each
platform. Installation never receives or reads credentials. The start phase consumes
startup-lifetime credentials and writes the AWS shared credentials file.

## Parameters

- `aws_access_key_id` - optional sensitive AWS access key ID.
- `aws_secret_access_key` - optional sensitive AWS secret access key.

The parameters must be supplied together or both omitted. Sensitive values are accepted
from `AWS_ACCESS_KEY_ID_FILE` and `AWS_SECRET_ACCESS_KEY_FILE`, as provided by ORC.

## Platforms

- Linux amd64 and arm64.
- macOS amd64 and arm64.
- Windows amd64.

Build + push (from the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`):

```bash
./orc build ./apps/aws --push
```

Validate locally without pushing (writes an OCI layout to disk):

```bash
./orc build ./apps/aws --output /tmp/aws-oci
```

Or pull the published artifact to verify its payload:

```bash
./orc pull aws:default /tmp/aws-pull
find /tmp/aws-pull -maxdepth 2 -type f -print
```

## Manual test

```bash
tmp=$(mktemp -d)
AWS_CLI_INSTALL_DIR="$tmp/aws-cli" AWS_CLI_BIN_DIR="$tmp/bin" sh apps/aws/install-aws.sh

printf '%s' test-access >"$tmp/access-key"
printf '%s' test-secret >"$tmp/secret-key"
HOME="$tmp/home" \
AWS_CLI_BIN_DIR="$tmp/bin" \
AWS_ACCESS_KEY_ID_FILE="$tmp/access-key" \
AWS_SECRET_ACCESS_KEY_FILE="$tmp/secret-key" \
sh apps/aws/start-aws.sh

HOME="$tmp/home" "$tmp/bin/aws" configure get aws_access_key_id
rm -rf "$tmp"
```
