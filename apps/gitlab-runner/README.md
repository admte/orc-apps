# gitlab-runner

Turns a machine into a GitLab Runner (19.6.0, shell executor) for a runner you created in GitLab. It
either takes that runner's jobs until it is stopped, or runs one job GitLab already handed out and
exits with that job's outcome. Jobs run as the `gitlab-runner` account.

- `url` (required): GitLab's address, e.g. `https://gitlab.com`
- `token` (required): authentication token (`glrt-`) of a runner created in GitLab
- `job` (required): file holding the runner token as `{"mode":"persistent","token":"glrt-…"}`, or one
  job as GitLab hands it to a runner
- `ca` (optional): PEM certificate GitLab's address is signed by; added to the system's trust store
- `ephemeral` (optional, default `false`): `true` to run the one job in `job`, `false` for a runner token

With a runner token the machine is one runner manager of that runner. With a job, the runner gets
the job from a proxy on loopback that passes its other calls to GitLab unchanged, so the machine
never holds the runner token, only the job's own token. The exit status is the job's outcome: 0
success, 1 failed, 2 canceled, 3 ended on GitLab's side.

A certificate given as `ca` is added to the system's trust store and stays trusted by every program
on the machine, also after it is removed from `ca`, until the machine is rebuilt. A job can reach
the loopback proxy; it serves the job nothing beyond what the job's own token already allows.
Stopping lets the job in flight finish, then ends whatever jobs left running.

Runs on Linux (amd64, arm64).
