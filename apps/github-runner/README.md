# github-runner

Turns a machine into a GitHub Actions self-hosted runner. It registers with your repository or
organization, runs your workflows as a system service, and unregisters when the machine is
retired.

- `url` (required): Repository or organization to register with, e.g. `https://github.com/org/repo`
- `token` (required): File holding a GitHub token that can register runners for `url`
- `labels` (optional): Comma-separated labels to register the runner with

Runs on Linux (amd64, arm64) and Windows (amd64).
