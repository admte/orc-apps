# terraform

Installs the HashiCorp Terraform CLI from HashiCorp Releases. The release archive is verified
against the vendor-published `SHA256SUMS` file before anything is unpacked.

```text
terraform/
  artifact.yaml
  install-terraform.sh
  uninstall-terraform.sh
```

Install-only: there is no start phase. The install phase fetches exactly the version the host
resolved (`APP_VERSION`), so the catalog version and the installed binary always agree.

## Parameters

None. This app takes no configuration.

## Versions

Discovered from GitHub releases of `hashicorp/terraform`. Prereleases (the `-alpha*`, `-beta*`
and `-rc*` tags HashiCorp publishes) are dropped, and `latest_per: minor` keeps only the newest
patch of each `major.minor` line, so the picker lists `1.16.0, 1.15.9, 1.14.9, …` instead of every
patch ever shipped. The leading `v` of a tag is normalized away by the evaluator, so `APP_VERSION`
is a plain `1.16.0`.

Pruned-away patch releases remain installable by exact reference (`terraform:1.15.7`); pruning
curates the listing, not the contract.

## Layout

- Binary: `/opt/terraform/<version>/terraform` — one subtree per version, so versions coexist.
- On `PATH`: `/usr/local/bin/terraform`, a symlink into the active version's subtree, repointed
  atomically on every install.
- Uninstall removes exactly `/opt/terraform/<version>/`, and drops the symlink only while it still
  points into that version's own subtree. Installing a new version before the old one is removed
  therefore keeps a working `terraform` on `PATH` throughout.
- A pre-existing `/opt/terraform` (from a manual install) is left alone; the app claims only its
  own `<version>/` subtree.

## Platforms

- Linux amd64 and arm64.

`unzip` is installed from the host package manager when missing, as stock cloud images often omit
it. Set `TERRAFORM_VERSION` to install a specific version when running the script by hand; set
`TERRAFORM_PREFIX` or `TERRAFORM_BIN_DIR` to relocate the versioned tree or the symlink directory.

## Build + Push

From the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`:

```bash
./orc build ./apps/terraform --push
```

Validate locally without pushing:

```bash
./orc build ./apps/terraform --output /tmp/terraform-oci
```

## Manual test

```bash
sudo APP_VERSION=1.16.0 sh apps/terraform/install-terraform.sh
terraform version
sudo APP_VERSION=1.16.0 sh apps/terraform/uninstall-terraform.sh
```
