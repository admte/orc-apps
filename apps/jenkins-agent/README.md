# jenkins-agent

Linux Jenkins Swarm agent app. It downloads `swarm-client.jar` from the Jenkins controller,
installs a matching Temurin JDK, registers a systemd service, and connects to Jenkins over
WebSocket.

```text
jenkins-agent/
  artifact.yaml
  install-jenkins-agent.sh
  start-jenkins-agent.sh
  drain-jenkins-agent.sh
  run-jenkins-agent.sh
```

Lifecycle scripts follow the `<phase>-jenkins-agent.sh` naming convention; `artifact.yaml`
does not repeat explicit install/start/drain commands.

Linux with systemd only (`linux/amd64`, `linux/arm64`).

## Parameters

- `jenkins_url` - **required** Jenkins controller URL, for example `https://jenkins.example.com`.
- `jenkins_username` - **required** Jenkins username for Swarm authentication.
- `jenkins_password` - **required** sensitive Jenkins API token or password.

The Swarm agent's labels are the pool name (sourced from the `pool.name` x-source), so they
are not a parameter. The agent name defaults to the current hostname.

The install phase copies the runner to `/etc/jenkins-agent/jenkins-agent.sh`. The systemd
service invokes this runner on every start and restart. Before launching the agent, it checks
the Jenkins controller Java major version and downloads a matching Temurin JDK when needed.
It also downloads the controller's `swarm-client.jar`, compares it with the local file, and
replaces it when they differ.

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

sudo sh start-jenkins-agent.sh
```

Check the agent in Jenkins under **Build Executor Status**. Drain with:

```bash
sudo sh drain-jenkins-agent.sh
```
