# github-runner

Multi-platform GitHub Actions self-hosted runner app. It registers a runner with a
GitHub repository or organization, starts the official runner process, and removes the
runner registration during drain.

```text
github-runner/
  artifact.yaml
  install-github-runner.sh
  start-github-runner.sh
  drain-github-runner.sh
  install-github-runner.ps1
  start-github-runner.ps1
  drain-github-runner.ps1
```

Lifecycle scripts follow the `<phase>-github-runner.<ext>` naming convention; `artifact.yaml`
does not repeat explicit install/start/drain commands.

## Parameters

- `url` - GitHub repository or organization URL, for example `https://github.com/org/repo`.
- `token` - sensitive GitHub token. The token must be able to create runner registration
  and removal tokens for the selected repository or organization.
- `labels` - optional comma-separated labels.
- `runner_name` - optional runner name. Defaults to the host name.
- `work_dir` - optional runner install directory. Defaults to `github-runner`.

## Build + Push

From the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`:

```bash
./orc build ./apps/github-runner --push
```

Validate locally without pushing:

```bash
./orc build ./apps/github-runner --output /tmp/github-runner-oci
```

Pull the published artifact to verify its payload:

```bash
./orc pull github-runner:default /tmp/github-runner-pull
find /tmp/github-runner-pull -maxdepth 2 -type f -print
```
