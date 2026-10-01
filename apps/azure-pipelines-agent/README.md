# azure-pipelines-agent

Runs an Azure Pipelines self-hosted agent on the node, executing pipeline jobs
for an Azure DevOps organization.

ORC discovers `install-azure-pipelines-agent`, `start-azure-pipelines-agent`,
`stop-azure-pipelines-agent` and `stopped-azure-pipelines-agent` by their
filenames, so no lifecycle commands are declared in `artifact.yaml`.

## Settings

| Setting | Required | Description |
|---------|----------|-------------|
| `url` | yes | Organization URL, for example `https://dev.azure.com/myorganization` |
| `token` | yes | Personal access token with the **Agent Pools (read, manage)** scope, delivered as a file because it is sensitive |
| `agent_pool` | no | Azure DevOps agent pool to join; defaults to the ORC pool's own name |
| `pool` | — | Filled by the platform from `pool.name` and used as the agent pool name when `agent_pool` is not given |

The agent pool must already exist in Azure DevOps — the agent joins a pool, it
does not create one. Each node registers under its own host name (`<pool>-<slot>`
for a pool member), so a pool of five nodes is five agents that appear and
disappear with them.

## Versioning

No `versions` block: an Azure Pipelines agent updates itself when the service
asks it to, so a pinned version would be replaced from the outside anyway. This
is the same reason github-runner declares none.

The installer reads the project's latest GitHub release for the current version
and the SHA-256 table its release notes publish, downloads
`vsts-agent-<platform>-<version>` from `download.agent.dev.azure.com`, and fails
if the checksum does not match. That release call is unauthenticated, so a very
large pool coming up at once could meet GitHub's anonymous rate limit.

## Lifecycle

- **install** downloads, verifies and unpacks the agent, and on Linux creates the
  `azagent` account it runs as. It deliberately registers nothing: a pool bake
  runs the install phase alone and snapshots the disk, so a registration made
  here would be shared by every clone of the image, along with the
  `.credentials` that `config.sh` writes.
- **start** registers this node once — `.agent` in the agent directory is its
  identity, and a restart reuses it — enables the agent through the API in case a
  previous drain left it disabled, then runs the agent host in the foreground as
  the platform's own service. If Azure DevOps answers that the pool no longer has
  an agent by this node's name (an admin deleted it), start drops the local
  identity and registers again; a lookup that fails keeps it. The PAT is passed
  as `VSTS_AGENT_INPUT_TOKEN` rather than `--token`, so it does not show up in the
  process list of the jobs the agent later spawns, and `TOKEN_FILE` is removed
  from the agent host's environment, so jobs do not inherit it.
- **stop** disables the agent through the API so the pool stops routing work
  here, then waits for the `Agent.Worker` already running. The wait belongs to
  the stop command: only it gets the full `stop.timeout`, while the `SIGINT` that
  follows is cut off after `grace`.
- **stopped** runs `config.sh remove`, and only when `APP_STOP_REASON` is
  `terminate`. A restart or an ordinary stop keeps the registration, disabled,
  for `start` to enable again.

## Layout

The agent is unpacked into `azure-pipelines-agent/` in the app's working
directory, with its `_work` tree beside it — the agent keeps its configuration
next to its binaries, so there is nothing to split into a versioned tree.

On Linux the agent runs as the `azagent` account, which the start script drops to
with `setpriv` (never `su` or `runuser`, which would move it out of the process
group the runtime signals). On Windows it runs as the service account.

## Limitations

- **Windows jobs can reach the PAT.** On Windows the agent, and every job it
  runs, uses the same account as the platform, which can read the app's param
  files. Treat the token as available to any pipeline that runs on the pool, and
  give it no scope beyond **Agent Pools (read, manage)**. On Linux jobs run as
  `azagent` and cannot read it.
- **Agent names must be unique within an Azure DevOps pool.** Registration uses
  `--replace`, so two ORC pools with the same name feeding one Azure DevOps pool
  (for example both with `agent_pool: Default`) produce nodes with the same host
  name that keep taking over each other's registration.
- **start always re-enables the agent.** An agent an Azure DevOps admin disabled
  on purpose comes back enabled the next time the node's app starts.

## Platforms

- Linux amd64 and arm64.
- Windows amd64 and arm64.

## Build

```bash
./orc build ./apps/azure-pipelines-agent --output /tmp/azp-oci
```
