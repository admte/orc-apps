# github-runner

Multi-platform GitHub Actions self-hosted runner app. It registers a runner with a GitHub
repository or organization and runs the official listener as a runtime-managed service, so an
agent upgrade or crash never touches a running build.

```text
github-runner/
  artifact.yaml
  install-github-runner.sh
  stop-github-runner.sh
  stopped-github-runner.sh
  install-github-runner.ps1
  stop-github-runner.ps1
  stopped-github-runner.ps1
```

Lifecycle scripts follow the `<phase>-github-runner.<ext>` naming convention. The app ships
`install`, `stop`, and `stopped` scripts for both platforms; `start` is an explicit command in
`artifact.yaml`, and an explicit command always wins over a same-named script.

`linux/amd64`, `linux/arm64`, and `windows/amd64`. macOS is not in the manifest: the runtime
has systemd and Windows SCM backends today, and darwin returns to the list when the launchd
service backend lands.

## Parameters

- `url` - **required** GitHub repository or organization URL, for example `https://github.com/org/repo`.
- `token` - **required** sensitive GitHub token. The token must be able to create runner
  registration and removal tokens for the selected repository or organization, and to edit a
  runner's labels (`administration` write on a repository, `organization_self_hosted_runners`
  write on an organization).

The runner name is the host name and its label is the pool name (sourced from the `pool.name`
x-source), so neither is a parameter. The runner installs under `github-runner` in the app's
working directory.

## Lifecycle

**install** creates the `ghrunner` service account on Linux, downloads the runner build
GitHub's service asks for, verifies its published checksum, and registers it with
`config.sh --unattended --replace`. It registers no service: the node owns the service
definition and generates it from `start:`. `svc.sh install` and `config.cmd --runasservice`
are deliberately not used.

**start** is a runtime-managed service (`start.service: github-runner`). On Linux the command
drops to `ghrunner` with `setpriv --reuid/--regid --init-groups` before `exec`ing `run.sh`;
`su` and `runuser` are deliberately not used, because they start a new session where the stop
signal can no longer reach the listener. On Windows the listener runs as the account the agent
runs as. Because it is a service and not a child of the agent, an agent upgrade or crash
leaves a running build alone; the node re-adopts the service by name afterwards.

**stop** (`stop-github-runner.{sh,ps1}`, `timeout: 1h`, `grace: 30s`) runs while the listener
is still alive. It looks the runner up by name and removes the pool label through
`DELETE .../actions/runners/{id}/labels/{label}`, so no new job is routed here, then waits
until no `Runner.Worker` process is running out of the runner directory and exits 0. It does
not deregister and it does not stop the listener — the runtime does that next, with
`stop.signal: SIGINT`, which the listener reads as "finish the current job, then exit".

Removing the pool label leaves the runner's default labels (`self-hosted`, the OS, the
architecture) in place. A workflow that targets those alone can still be routed to this runner
between the label removal and the stop signal.

**stopped** (`stopped-github-runner.{sh,ps1}`, `timeout: 120s`) runs after every exit and
looks at `APP_STOP_REASON`. On `terminate` — the node is ending and this install will never
start again — it mints a remove token and runs `config.sh remove`, retrying a few times on a
transient API error; the listener is already gone by then, so GitHub does not refuse the
removal as busy. On every other reason (`restart`, `stop`, `shutdown`, `exit`) it exits 0
immediately and leaves the registration intact, because the same install starts again against
it.

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

## Manual test

Requires root and a GitHub token for the target repository or organization:

```bash
sudo env \
  URL=https://github.com/org/repo \
  TOKEN=ghp_... \
  POOL=my-pool \
  sh install-github-runner.sh

# what the generated service runs
sudo sh -c 'cd github-runner && exec setpriv --reuid=ghrunner --regid=ghrunner \
  --init-groups env HOME="$PWD" ./run.sh'
```

Start a workflow job on the runner, then in another shell drain it — the script removes the
label, waits for the job, and leaves the listener running:

```bash
sudo env URL=https://github.com/org/repo TOKEN=ghp_... POOL=my-pool \
  sh stop-github-runner.sh
```

Deregistration is a separate step, and only happens for a terminating node:

```bash
sudo env URL=https://github.com/org/repo TOKEN=ghp_... APP_STOP_REASON=stop \
  sh stopped-github-runner.sh      # keeps the registration
sudo env URL=https://github.com/org/repo TOKEN=ghp_... APP_STOP_REASON=terminate \
  sh stopped-github-runner.sh      # removes it
```
