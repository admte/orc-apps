# gitlab-runner

Turns a machine into a GitLab Runner (19.6.0, shell executor) for a runner created in GitLab. It
either takes that runner's jobs until it is stopped, or takes one job and exits. Jobs run as the
`gitlab-runner` account.

- `url` (required): GitLab's address, e.g. `https://gitlab.com`
- `token` (required): authentication token (`glrt-`) of a runner created in GitLab, or a runner
  credential as a JSON object
- `ephemeral` (optional, default `false`): `true` to take one job, then exit

`token` is read by its shape. A value whose first non-blank character is `{` is a credential the
host supplies; anything else is a runner token.

| `token` | `ephemeral` | What runs |
| --- | --- | --- |
| a runner token | `false` | a runner that takes jobs until stopped, against `url` |
| a runner token | `true` | one job taken straight from GitLab |
| `{"mode":"persistent","url":…,"token":…}` | `false` | a runner that takes jobs until stopped |
| `{"mode":"job","url":…,"job":{…}}` | `true` | the one job supplied |

A JSON credential names its GitLab in its own `url`, and `url` is then not used. An unknown mode,
or one that does not fit `ephemeral`, stops the start.

A runner that takes jobs until stopped is one runner manager of that runner on this machine.

**One job from GitLab.** The runner talks to GitLab through a proxy on loopback, which passes its
job requests to GitLab, one at a time, until one answers with a job, and answers every later one
with "no job". The machine prints the job's outcome and exits 0 once the job is over, however it
ended (success, failed, canceled, ended on GitLab's side, or past its timeout), so that a failed CI
job is not mistaken for a broken machine. It exits 1 only when GitLab refuses the token or the
runner cannot start.

**One supplied job.** The job, exactly as GitLab handed it to a runner, is served to the runner by
the same proxy, which passes the runner's other calls to GitLab unchanged. The machine never holds
a runner token, only the job's own token. The exit status is the job's outcome: 0 success, 1
failed, 2 canceled, 3 ended on GitLab's side.

GitLab's certificate must chain to a root the system trusts. A job can reach the loopback proxy; it
serves the job nothing beyond what the job's own token already allows. The runner's configuration,
which may hold the runner token, is root-only and removed when the runner stops. Stopping lets the
job in flight finish, then ends whatever jobs left running.

Runs on Linux (amd64, arm64).
