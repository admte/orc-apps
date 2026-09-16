# github-runner

Multi-platform GitHub Actions self-hosted runner app. It registers a runner with a GitHub
repository or organization and runs the official listener as a runtime-managed service, so an
agent upgrade or crash never touches a running build.

```text
github-runner/
  artifact.yaml
  install-github-runner.sh
  start-github-runner.sh
  stop-github-runner.sh
  stopped-github-runner.sh
  install-github-runner.ps1
  start-github-runner.ps1
  stop-github-runner.ps1
  stopped-github-runner.ps1
```

Lifecycle scripts follow the `<phase>-github-runner.<ext>` naming convention. The app ships
`install`, `start`, `stop`, and `stopped` scripts for both platforms and no explicit command
for any phase, so each one resolves from the package by name and per platform.

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
GitHub's service asks for, verifies its published checksum, unpacks it under `github-runner`,
and hands it to the service account. That is the whole of it: it does **not** register the
runner, and the unpacked directory it leaves behind is unconfigured. It registers no service
either — the node owns the service definition and generates it from `start:`, so `svc.sh
install` and `config.cmd --runasservice` are deliberately not used.

Registration happens at start, so installation leaves no runner identity or registration
credentials in the unpacked directory.

**start** (`start-github-runner.{sh,ps1}`) is a runtime-managed service: the package ships a
start script and `artifact.yaml` names `start.service: github-runner`, and a start command that
resolves — from config or, as here, from a packaged script — together with a `service` name is
what selects runtime-managed service mode.

The script registers, then becomes the listener. It looks for `.runner` in the runner
directory, the file `config.sh` writes once a directory is configured. If it is missing,
the script mints a fresh registration token and runs
`config.sh --name <hostname> --url <url> --token <fresh> --unattended --replace`
(plus `--labels <pool>` when a pool label is set) as the service account, so the node registers
under its **own** host name. If `.runner` is present the node already has an identity — the
ordinary service restart — and registration is skipped, which is also what `config.sh` itself
demands: it refuses to configure an already-configured directory. The registration token is
minted at the moment it is used and never written anywhere.

It then **restores the pool label**, on both paths and idempotently: it looks the runner up by
name (walking the paginated runner list, the same lookup `stop` uses) and
`POST .../actions/runners/{id}/labels` with `{"labels":["<pool>"]}`, which adds a label without
replacing the ones already there. This is not cosmetic. `stop` takes the pool label off through
the API to stop new jobs routing here during a drain, and the registration survives every stop
reason except `terminate` — so without this step a drained node would come back online with
`.runner` intact, skip `config.sh` (which is what carries `--labels`), and sit there holding
only its default labels: online, healthy-looking, and never matched by `runs-on: <pool-name>`
again. The step is skipped entirely when no pool label is set, and a failure in it is logged
loudly but never stops the runner — a runner with no label still beats a node that will not
start.

It then `exec`s the listener. On Linux it drops to `ghrunner` with
`setpriv --reuid/--regid --init-groups` first; `su` and `runuser` are deliberately not used,
because they start a new session where the stop signal can no longer reach the listener. On
Windows the listener runs as the account the agent runs as. Because it is a service and not a
child of the agent, an agent upgrade or crash leaves a running build alone; the node re-adopts
the service by name afterwards.

**stop** (`stop-github-runner.{sh,ps1}`, `timeout: 1h`, `grace: 30s`) runs while the listener
is still alive. It looks the runner up by name and removes the pool label through
`DELETE .../actions/runners/{id}/labels/{label}`, so no new job is routed here, then waits
until no `Runner.Worker` process is running out of the runner directory and exits 0. It does
not deregister and it does not stop the listener — the runtime does that next, with
`stop.signal: SIGINT`, which the listener reads as "finish the current job, then exit".

Removing the pool label leaves the runner's default labels (`self-hosted`, the OS, the
architecture) in place. A workflow that targets those alone can still be routed to this runner
between the label removal and the stop signal. The label comes back on the next start, which
re-adds it through the API, so a drained runner rejoins its pool.

**stopped** (`stopped-github-runner.{sh,ps1}`, `timeout: 120s`) runs after every exit and
looks at `APP_STOP_REASON`. On `terminate` — the node is ending and this install will never
start again — it mints a remove token and runs `config.sh remove`, retrying a few times on a
transient API error; the listener is already gone by then, so GitHub does not refuse the
removal as busy. On every other reason (`restart`, `stop`, `shutdown`, `exit`) it exits 0
immediately and leaves the registration intact, because the same install starts again against
it and start reuses it on sight of `.runner`.

The three hooks meet at that one file. `config.sh remove` deletes `.runner` and
`.credentials`, so a `terminate` that is somehow followed by another start finds no identity
and registers fresh rather than starting an unconfigured listener; every other stop reason
leaves `.runner` in place, and start reuses it. Labels ride alongside: `stop` removes the pool
label and `start` puts it back, whichever branch it took, so the identity and the label are
both whole again by the time the listener comes up.

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
# downloads and unpacks only; leaves the runner unconfigured
sudo env \
  URL=https://github.com/org/repo \
  TOKEN=ghp_... \
  sh install-github-runner.sh

# what the generated service runs: registers on first start, then execs the listener
sudo env \
  URL=https://github.com/org/repo \
  TOKEN=ghp_... \
  POOL=my-pool \
  sh start-github-runner.sh
```

Run it twice: the first run logs `registering`, the second finds `.runner` and logs
`already registered`. Both runs log `pool label ensured`.

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
