# gcloud

Installs Google Cloud CLI and optionally activates a service account.

```text
gcloud/
  artifact.yaml
  install-gcloud.sh
  start-gcloud.sh
  install-gcloud.ps1
  start-gcloud.ps1
```

`artifact.yaml` explicitly selects the Unix or PowerShell lifecycle commands. The install
phase never reads the service account key. During start, ORC provides the JSON key as a
startup-lifetime file and `gcloud auth activate-service-account` stores the resulting
credentials in the Google Cloud CLI configuration.

## Parameter

- `service_account_key` - optional sensitive service account JSON key with
  `contentMediaType: application/json` and `lifetime: startup`.

ORC supplies it through `SERVICE_ACCOUNT_KEY_FILE`.

## Platforms

- Linux amd64 and arm64.
- macOS amd64 and arm64.
- Windows amd64.

Linux ARM and macOS archives require Python 3.10-3.14. The installer provisions Python
through a supported Linux package manager when running as root; macOS must provide it.

## Build

```bash
./orc build ./apps/gcloud --output /tmp/gcloud-oci
```

## Manual test

Installation without credentials:

```bash
tmp=$(mktemp -d)
GCLOUD_INSTALL_DIR="$tmp/google-cloud-sdk" \
GCLOUD_BIN_DIR="$tmp/bin" \
sh apps/gcloud/install-gcloud.sh

"$tmp/bin/gcloud" version
```

Activation with a real service account key:

```bash
CLOUDSDK_CONFIG="$tmp/config" \
GCLOUD_BIN_DIR="$tmp/bin" \
SERVICE_ACCOUNT_KEY_FILE=/path/to/service-account.json \
sh apps/gcloud/start-gcloud.sh

CLOUDSDK_CONFIG="$tmp/config" "$tmp/bin/gcloud" auth list
rm -rf "$tmp"
```
