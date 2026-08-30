# jenkins-agent

Linux Jenkins Swarm agent app. It downloads `swarm-client.jar` from the Jenkins controller,
installs a matching Temurin JDK, and connects to Jenkins over WebSocket as a runtime-managed
systemd service.

```text
jenkins-agent/
  artifact.yaml
  install-jenkins-agent.sh
  stop-jenkins-agent.sh
  run-jenkins-agent.sh
  jenkins-agent-common.sh
```

Lifecycle scripts follow the `<phase>-jenkins-agent.sh` naming convention. The app ships an
`install` and a `stop` script; `start` is an explicit command in `artifact.yaml`, and an
explicit command always wins over a same-named script.

Linux with systemd only (`linux/amd64`, `linux/arm64`).

## Parameters

- `jenkins_url` - **required** Jenkins controller URL, for example `https://jenkins.example.com`.
- `jenkins_username` - **required** Jenkins username for Swarm authentication.
- `jenkins_password` - **required** sensitive Jenkins API token or password.

The Swarm agent's labels are the pool name (sourced from the `pool.name` x-source), so they
are not a parameter. The agent name is the current hostname; `-disableClientsUniqueId` keeps
the node name on the controller exactly that.

The Jenkins account must hold the **Agent/Disconnect** permission in addition to
**Agent/Create** and **Agent/Connect**: the stop phase marks the node temporarily offline
through `toggleOffline`, and without that permission a node stop cannot drain the agent.

## Lifecycle

**install** provisions the host: the `jenkins` system user, `/var/lib/jenkins-agent`, the
logging config, the password file, and a copy of the runner and its helper under
`/etc/jenkins-agent/`. It writes no unit file and enables nothing for boot — the node owns
the service definition and generates it from `start:`.

**start** is a runtime-managed service (`start.service: jenkins-agent`, `restart: always`).
The command drops to the `jenkins` account with `setpriv --reuid/--regid --init-groups` and
`exec`s the runner, which `exec`s the JVM, so the Swarm client is the service's own process
and the stop signal reaches it. `su` and `runuser` are deliberately not used: they start a
new session, which is what used to keep the stop from reaching the agent.

Before launching the agent, the runner checks the Jenkins controller Java major version and
downloads a matching Temurin JDK when needed. It also downloads the controller's
`swarm-client.jar`, compares it with the local file, and replaces it when they differ. The
runner re-reads the password file on every restart, which is why install writes its own copy
rather than relying on the sensitive parameter file (that one is withdrawn once the app has
started).

**stop** (`stop-jenkins-agent.sh`, `timeout: 30m`, `grace: 30s`) runs while the agent is
still connected. It reads the node's state, marks it temporarily offline when it is not
already (`toggleOffline` is a toggle, so the current state is read first), then polls until
the node reports idle and exits 0. It never stops the service itself — the runtime does that
next, and only after this script has said the agent is safe to signal.

There is no **stopped** hook: a Swarm node is transient and disappears from the controller
when the client disconnects, so there is no external registration left to release.

## Build + Push

From the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`:

```bash
./orc build ./apps/jenkins-agent --push
```

Validate locally without pushing:

```bash
./orc build ./apps/jenkins-agent --output /tmp/jenkins-agent-oci
```

Pull the published artifact to verify its payload:

```bash
./orc pull jenkins-agent:default /tmp/jenkins-agent-pull
find /tmp/jenkins-agent-pull -maxdepth 2 -type f -print
```

## Manual test

Requires root and a Jenkins controller with the Swarm plugin installed:

```bash
sudo env \
  JENKINS_URL=https://jenkins.example.com \
  JENKINS_USERNAME=agent-user \
  JENKINS_PASSWORD=token-or-password \
  sh install-jenkins-agent.sh

# what the generated service runs
sudo setpriv --reuid=jenkins --regid=jenkins --init-groups \
  env HOME=/var/lib/jenkins-agent \
  /etc/jenkins-agent/jenkins-agent.sh \
  https://jenkins.example.com agent-user /var/lib/jenkins-agent/jenkins.password \
  "$(hostname)" my-pool /var/lib/jenkins-agent /var/lib/jenkins-agent/logging.properties
```

Check the agent in Jenkins under **Build Executor Status**. In another shell, drain it — the
script returns once the agent is offline and idle, and leaves the running agent alone:

```bash
sudo env \
  JENKINS_URL=https://jenkins.example.com \
  JENKINS_USERNAME=agent-user \
  APP_STOP_REASON=terminate \
  sh stop-jenkins-agent.sh
```
