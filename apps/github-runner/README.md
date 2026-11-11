# github-runner

Turns a machine into a GitHub Actions self-hosted runner. It registers with your repository or
organization, runs your workflows as a system service, and unregisters when the machine is
retired.

- `url` (required): Repository or organization to register with, e.g. `https://github.com/org/repo`
- `token` (required): File holding a GitHub token that can register runners for `url`
- `labels` (optional): Comma-separated labels to register the runner with
- `ephemeral` (optional, default `false`): Take one job, then exit. A just-in-time runner
  configuration needs `true`, a persistent JSON registration `false`; a token registers either way

`token` may also hold a runner registration as a JSON object. With `"mode": "jit"` it carries a
just-in-time runner configuration (`name`, `jitconfig`): the runner starts from it without
registering, takes one job and exits, and GitHub removes it afterwards, so nothing is deregistered
when the machine is retired. A just-in-time runner retired before it took a job stays registered
on GitHub: this app does not remove it. The configuration reaches the runner through its
environment (`ACTIONS_RUNNER_INPUT_JITCONFIG`), never on a command line, so it does not show in
the process list.

Runs on Linux (amd64, arm64) and Windows (amd64).
