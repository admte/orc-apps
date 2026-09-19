# gitlab-runner

Runs a GitLab Runner on the node, executing CI/CD jobs for a GitLab project,
group or instance.

ORC discovers `install-gitlab-runner`, `start-gitlab-runner`,
`stop-gitlab-runner` (Windows only) and `stopped-gitlab-runner` by their
filenames, so no lifecycle commands are declared in `artifact.yaml`.

## Settings

| Setting | Required | Description |
|---------|----------|-------------|
| `url` | yes | GitLab instance the runner connects to, for example `https://gitlab.com` |
| `token` | yes | Runner authentication token (`glrt-…`), delivered as a file because it is sensitive |
| `executor` | no | `shell` (default) or `docker`; the docker executor needs the docker app on the same node |
| `pool` | — | Filled by the platform from `pool.name` and appended to the runner description |

Create the runner in GitLab first (**Settings > CI/CD > Runners > New project
runner**), set its tags and options there, and paste the authentication token it
gives you. Tags belong to the runner as GitLab stores it, not to this app: with
an authentication token, `register` only attaches this node as a *runner
manager* to a runner that already exists.

## Versioning

Versions are discovered from the project's GitLab releases
(<https://gitlab.com/gitlab-org/gitlab-runner>), one per release line. Nothing is
pinned in this repo: a new GitLab Runner release shows up without a change here.

The installer downloads `gitlab-runner-<os>-<arch>` for the node's platform from
GitLab's release bucket and verifies it against the SHA-256 the release index
publishes for that exact file. A mismatch fails the install.

## Lifecycle

- **install** downloads and verifies the binary and creates the `gitlab-runner`
  account that jobs run as. It deliberately registers nothing: a pool bake runs
  the install phase alone and snapshots the disk, so a registration made here
  would be shared by every clone of the image.
- **start** registers this node once — the `[[runners]]` entry in `config.toml`
  is its identity, and a restart reuses it — then runs the runner in the
  foreground as the platform's own service. The token is passed through the
  environment, never as a flag, so it does not show up in the process list of
  the jobs the runner later spawns.
- **stop** drains. On Linux the declared `SIGQUIT` is gitlab-runner's own
  graceful shutdown: it stops accepting jobs and exits when the running one
  finishes. Windows has no such signal, so `stop-gitlab-runner.ps1` waits for the
  job in flight instead. Neither path can stop GitLab from handing out one more
  job while it waits, because taking a runner out of rotation needs an API token
  this app is not given.
- **stopped** unregisters, and only when `APP_STOP_REASON` is `terminate`. A
  restart or an ordinary stop keeps the registration, because the same install
  comes back against the same `config.toml`.
- **uninstall** unregisters best-effort and removes that version's tree, taking
  the `gitlab-runner` exposure with it only while it still points into that tree.

Unregistering removes this node's runner *manager*. The runner itself was created
in GitLab and stays there — delete it in the UI or through the REST API when the
pool is gone for good.

## Layout

- Linux: `/opt/gitlab-runner/<version>/gitlab-runner`, symlinked into
  `/usr/local/bin`, with `/opt/gitlab-runner/current` pointing at the active
  version. `config.toml` and `builds/` live in the app's working directory.
- Windows: `%ProgramFiles%\gitlab-runner\<version>`, exposed through a `current`
  junction that is added to the machine `PATH`.

The runner process itself stays root (that is what lets the platform signal it);
jobs run as the `gitlab-runner` account, selected with `run --user`. On Windows
jobs run as the service account, since dropping privileges there needs a
password.

## Platforms

- Linux amd64 and arm64.
- Windows amd64 and arm64.

## Build

```bash
./orc build ./apps/gitlab-runner --output /tmp/gitlab-runner-oci
```

After publishing, inspect discovered versions with:

```bash
./orc versions gitlab-runner
```
