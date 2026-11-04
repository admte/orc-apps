# github-runner

Turns a machine into a GitHub Actions self-hosted runner. It registers with your repository or
organization, runs your workflows as a system service, and unregisters when the machine is
retired.

| Param | Required | Description |
|---|---|---|
| `url` | yes | Repository or organization to register with, e.g. `https://github.com/org/repo` |
| `token` | yes | File holding a GitHub token that can register runners for `url` |
| `pool` | no | Extra label to register the runner with |

Runs on Linux (amd64, arm64) and Windows (amd64).
