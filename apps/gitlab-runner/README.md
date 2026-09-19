# gitlab-runner

Runs a GitLab Runner on the node, executing CI/CD jobs for a GitLab project,
group or instance.

ORC discovers `install-gitlab-runner`, `start-gitlab-runner`,
`stop-gitlab-runner`, `stopped-gitlab-runner` and `uninstall-gitlab-runner` by
their filenames, so no lifecycle commands are declared in `artifact.yaml`.

## Settings

| Setting | Required | Description |
|---------|----------|-------------|
| `url` | yes | Project or group URL, for example `https://gitlab.com/group/project`. The instance URL alone creates an instance runner, which needs an administrator token. |
| `token` | yes | Access token used to create, pause and delete this node's runner; needs the `create_runner` and `manage_runner` scopes. Delivered as a file because it is sensitive. |
| `executor` | no | `shell` (default) or `docker`; the docker executor needs the docker app on the same node. |
| `pool` | — | Filled by the platform from `pool.name` and applied as the runner's tag. |

Nothing is created in the GitLab UI beforehand: like github-runner, this app
takes an access token and creates the runner itself, one per node, so a pool of
five nodes is five runners that appear and disappear with them.

Each runner is tagged with the pool name, so `tags: [<pool>]` in
`.gitlab-ci.yml` routes a job to that pool — the counterpart of `runs-on:
<pool>` on GitHub. A node whose pool name is not available takes untagged jobs
instead, so it does not sit idle with nothing able to select it.

## Versioning

Versions are discovered from the project's GitLab releases
(<https://gitlab.com/gitlab-org/gitlab-runner>), one per release line. Nothing is
pinned in this repo: a new GitLab Runner release shows up without a change here.

The installer downloads `gitlab-runner-<os>-<arch>` for the node's platform from
GitLab's release bucket and verifies it against the SHA-256 the release index
publishes for that exact file. A mismatch fails the install.

## Lifecycle

- **install** downloads the binary, verifies it and only then publishes it, and
  on Linux creates the `gitlab-runner` account that jobs run as. It deliberately
  creates no runner: a pool bake runs
  the install phase alone and snapshots the disk, so a runner created here would
  be baked into an image every clone shares, along with its authentication token.
- **start** creates this node's runner through `POST /user/runners` when there is
  none, records its id, and registers it locally; on an ordinary restart it
  reuses the existing one and resumes it, because `stop` left it paused. The
  runner token is passed through the environment, never as a flag, so it does not
  show up in the process list of the jobs the runner later spawns.
- **stop** pauses the runner through the API so the queue stops routing work
  here, then waits for the job already running. The wait belongs to the stop
  command on both platforms: only it gets the full `stop.timeout`, while the
  `SIGQUIT` that follows — gitlab-runner's own graceful shutdown — is cut off
  after `grace`, which is thirty seconds and not a build.
- **stopped** deletes the runner, and only when `APP_STOP_REASON` is `terminate`.
  A restart or an ordinary stop keeps it, paused, for `start` to resume.
  `unregister` alone is not enough here: a runner created through the API
  survives it, so the id recorded at creation is what the delete uses. The delete
  goes first and `config.toml` is removed after it, so a node can never come back
  up holding the token of a runner GitLab no longer has — which would look
  healthy and never be given a job.
- **uninstall** deletes the runner best-effort and removes that version's tree,
  taking the `gitlab-runner` exposure with it only while it still points into
  that tree. The runner's configuration and job trees are cleared only once the
  last installed version is gone.

## Layout

- Linux: `/opt/gitlab-runner/<version>/gitlab-runner`, symlinked into
  `/usr/local/bin`, with `/opt/gitlab-runner/current` pointing at the active
  version. `config.toml`, `runner.id` and `builds/` live in the app's working
  directory.
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
