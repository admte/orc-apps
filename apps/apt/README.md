# apt

Installs the Debian or Ubuntu packages you list, so a machine has the tools your work needs
without anyone logging in to set it up. The list is applied again every time the app starts.

- `packages` (required): Space-separated package names, e.g. `git curl htop`

Runs on Linux (amd64, arm64) with `apt-get`.
