# jenkins-agent

Multi-platform Jenkins Swarm agent app. It downloads `swarm-client.jar` from the Jenkins
controller, installs a matching Temurin JDK, and connects to Jenkins over WebSocket as a
runtime-managed service.

```text
jenkins-agent/
  artifact.yaml
  install-jenkins-agent.sh
  start-jenkins-agent.sh
  stop-jenkins-agent.sh
  run-jenkins-agent.sh
  jenkins-agent-common.sh
  install-jenkins-agent.ps1
  start-jenkins-agent.ps1
  stop-jenkins-agent.ps1
  run-jenkins-agent.ps1
```

Lifecycle scripts follow the `<phase>-jenkins-agent.<ext>` naming convention. The app ships
`install`, `start`, and `stop` scripts for both platforms and no explicit command for any
phase, so each one resolves from the package by name and per platform.

`linux/amd64`, `linux/arm64`, and `windows/amd64`. macOS is not in the manifest: the runtime
has systemd and Windows SCM service backends today, and darwin returns to the list when the
launchd backend lands.

`run-jenkins-agent.{sh,ps1}` is not a lifecycle script — it is the agent itself, which
install copies to a fixed path and start invokes.

## Parameters

- `jenkins_url` - **required** Jenkins controller URL, for example `https://jenkins.example.com`.
- `jenkins_username` - **required** Jenkins username for Swarm authentication.
- `jenkins_password` - **required** sensitive Jenkins API token or password.
- `tls_ca` - the project's trust chain, sourced from the platform (`x-source: ca.bundle`)
  and delivered as a file the phase reads through `TLS_CA_FILE`. Never entered by hand,
  and not required: see [TLS trust](#tls-trust).

The Swarm agent's labels are the pool name (sourced from the `pool.name` x-source), so they
are not a parameter. The agent name is the host name — `hostname` on Linux, `%COMPUTERNAME%`
on Windows; `-disableClientsUniqueId` keeps the node name on the controller exactly that, and
it is the name `stop` looks up.

The Jenkins account must hold the **Agent/Disconnect** permission in addition to
**Agent/Create** and **Agent/Connect**: the stop phase marks the node temporarily offline
through `toggleOffline`, and without that permission a node stop cannot drain the agent. The
runner also calls `/scriptText`, which needs **Overall/RunScripts**.

## Where things live

| | Linux | Windows |
|---|---|---|
| Agent directory (`-fsroot`) | `/var/lib/jenkins-agent` | `C:\ProgramData\jenkins-agent` |
| Runner | `/etc/jenkins-agent/jenkins-agent.sh` | `C:\ProgramData\jenkins-agent\bin\jenkins-agent.ps1` |
| Password file | `<agent dir>/jenkins.password` | `<agent dir>\jenkins.password` |
| Logging config | `<agent dir>/logging.properties` | `<agent dir>\logging.properties` |
| JDK | `<agent dir>/java-temurin-<major>` | `<agent dir>\java-temurin-<major>` |
| Staged platform CA | `<agent dir>/platform-ca.pem` | `<agent dir>\platform-ca.pem` |
| curl trust file | `<agent dir>/ca-trust.pem` | — (validation callback) |
| JVM truststore | `<agent dir>/truststore.p12` | `<agent dir>\truststore.p12` |
| Runs as | the `jenkins` system account | the account the runtime runs as |

`AGENT_DIR` and `RUNNER_DIR` override the first two on both platforms; they exist for the
manual test below, not for normal operation.

## Lifecycle

**install** provisions the host and contacts nothing. On Linux it creates the `jenkins`
system user, `/var/lib/jenkins-agent`, the logging config, the password file, and a copy of
the runner and its helper under `/etc/jenkins-agent/`. On Windows it creates
`C:\ProgramData\jenkins-agent`, writes the same logging config, writes the password file with
inheritance dropped and access rebuilt for `LocalSystem`, the local `Administrators` group,
and the installing account, and copies the runner to `bin\jenkins-agent.ps1`. It creates no
service account on Windows — there is no `setpriv` there and the app runs as the runtime's own
account — and on neither platform does it write a unit file, register an SCM service, or enable
anything for boot: the node owns the service definition and generates it from `start:`.

Nothing install writes is identity-bearing, and that is deliberate. Install is the phase a
**pool bake** runs: it runs on a builder node, snapshots the disk, and destroys the builder,
so everything install leaves behind is shared by every clone of that image. The agent's
identity is its host name, and it is minted where it belongs — when the Swarm client connects,
once per running node.

**start** (`start-jenkins-agent.{sh,ps1}`) is a runtime-managed service
(`start.service: jenkins-agent`, `restart: always`). There is no `start.command`: the packaged
start script resolves per platform, and a start command that resolves — from config or from a
packaged script — together with a `service` name is what selects runtime-managed service mode.

The start script stages the platform CA (see [TLS trust](#tls-trust)) and otherwise only
assembles the runner's arguments from the params and the host name. On
Linux it drops to the `jenkins` account with `setpriv --reuid/--regid --init-groups` and
`exec`s the runner, which `exec`s the JVM, so the Swarm client is the service's own process
and the stop signal reaches it. `su` and `runuser` are deliberately not used: they start a new
session, which is what used to keep the stop from reaching the agent. On Windows the runner
runs in the start script's own PowerShell session and the JVM is its child; Windows has no
`exec`, and the runtime's service shim ends the whole process tree, so the stop still lands.

Before launching the agent, the runner builds its trust material (see
[TLS trust](#tls-trust)) and then asks the controller — through an authenticated
`/scriptText` Groovy call carrying a CSRF crumb — which Java major version it runs and which
Swarm plugin version it serves, and downloads a matching Temurin JDK when the local one does
not match. It also downloads the controller's own `swarm-client.jar`, compares it with the
local file, and replaces it when they differ. The runner re-reads the password file on every
restart, which is why install writes its own copy rather than relying on the sensitive
parameter file (that one is withdrawn once the app has started).

**stop** (`stop-jenkins-agent.{sh,ps1}`, `timeout: 30m`, `grace: 30s`) runs while the agent is
still connected. It reads the node's state, marks it temporarily offline when it is not already
(`toggleOffline` is a toggle, so the current state is read first), then polls until the node
reports idle and exits 0. A 404 from the controller means the agent is not registered — nothing
to quiesce — and exits 0 as well. It never stops the service itself: the runtime does that next,
and only after this script has said the agent is safe to signal.

Nothing clears the offline mark on the way back. A stop that is really a restart relies on
`-deleteExistingClients`, which drops the stale node when the client reconnects, so the fresh
node starts online — which is why that flag stays in the runner.

On Linux the service manager's stop signal reaches the JVM, which shuts down inside the 30s
grace. On Windows a subprocess gets no signal, so the JVM is ended when the grace expires; the
stop hook has already drained it by then, which is the whole point of quiescing first.

There is no **stopped** hook: a Swarm node is transient and disappears from the controller when
the client disconnects, so there is no external registration left to release.

## TLS trust

The Jenkins controller is usually served with a **platform-issued** certificate, and both
halves of this app have to verify it: the HTTP calls (`/crumbIssuer`, `/scriptText`,
`swarm-client.jar`, and the stop hook's `/computer/<name>` calls) and the JVM the Swarm
client runs in. The two do not share a trust store, so each is dealt with separately.

The chain comes from the `tls_ca` param. Nothing about it is entered by an operator: the
platform resolves `x-source: ca.bundle` to the project's chain (intermediate + root) and the
runtime materializes it as a file, whose path each phase reads from `TLS_CA_FILE`.

**Additive, never authoritative.** Both platforms *add* the chain to the trust store they
already have; neither replaces it. That is what makes the param optional in effect: the
platform hands this app its CA whether or not the controller is served with it, so a
controller with a publicly issued certificate — or a plain `http://` one — keeps working
untouched, and so does an assignment for which the param never resolved at all.

**No path disables verification.** There is no `curl -k`, no `-SkipCertificateCheck`, and no
callback that returns true for an unverified peer. When a chain is supplied and the handshake
still fails, the phase fails and says so.

### Where the chain is applied

| | Linux | Windows |
|---|---|---|
| Staged by `start` at | `<agent dir>/platform-ca.pem` | `<agent dir>\platform-ca.pem` |
| HTTP calls | `curl --cacert <agent dir>/ca-trust.pem` | per-process certificate validation callback |
| `ca-trust.pem` is | the OS CA bundle + the platform chain | — |
| JVM | `-Djavax.net.ssl.trustStore=<agent dir>/truststore.p12` | same |
| `truststore.p12` is | a copy of the JDK's `cacerts` + the platform chain | same |

`start` stages the chain because the runtime's own materialization is not reachable where it
is needed: on Linux the param file is `0600` in a `0700` directory owned by the account the
runtime runs as, and the agent runs as `jenkins` after `setpriv`; on both platforms the stop
hook is a separate phase. `start` re-stages on every start and **deletes** the staged copy
when nothing was supplied, so a controller that moved to a publicly issued certificate is not
left verifying against yesterday's chain. `stop` prefers its own `TLS_CA_FILE` and falls
back to the staged copy.

Nothing is done at **install**: the platform's certificates are short-lived and are renewed by
restarting the app, and install is also the phase a pool bake snapshots — a chain baked into
an image would be stale on first boot.

**curl** gets one PEM file that is the OS trust store followed by the platform chain, rebuilt
on every start. `--cacert` replaces curl's default, which is exactly why the OS store is
concatenated in rather than dropped. On a host with no recognizable OS bundle the runner says
so and verifies against the platform chain alone — still verification, just a narrower anchor
set.

**Invoke-WebRequest** has no `--cacert`; its verification is the OS store's. Rather than write
to `LocalMachine\Root` (needs admin, outlives the app, goes stale on the next renewal), the
runner installs a `ServicePointManager.ServerCertificateValidationCallback` for the lifetime of
its own process. The callback accepts a certificate in exactly two cases: the OS already
validated it (`SslPolicyErrors.None`), or the chain rebuilds cleanly — with the supplied
anchors and the peer-presented intermediates in `ExtraStore` — and terminates at one of the
supplied certificates. A name mismatch, an expired leaf, a missing certificate, or any chain
status other than `UntrustedRoot` is still fatal.

**The JVM** does not read the OS trust store, and the Temurin JDK the runner downloads ships
its own `cacerts`, so the callback above does nothing for the Swarm client. The runner copies
that JDK's `cacerts` to `<agent dir>/truststore.p12`, imports each certificate of the chain
into the copy with `keytool -importcert -noprompt -trustcacerts -alias orc-platform-ca-<n>`,
and starts the client with `-Djavax.net.ssl.trustStore` pointed at it.

A copy rather than the JDK's own `cacerts`, for three reasons: the runner replaces the whole
JDK directory whenever the controller's Java major version changes, so an import into the
downloaded artifact would be silently discarded by the next swap; a mutated artifact no longer
matches what was downloaded; and rebuilding from scratch is idempotent by construction, with
no alias to delete first and no way to drift across the restarts `restart: always` produces.
Copying `cacerts` rather than building an empty store is what keeps the public roots, so the
same truststore also verifies a publicly issued controller certificate. The rebuild runs
**after** the JDK is settled, so a JDK swap is always followed by a fresh import.

`keytool -importcert` takes one certificate per alias, so a bundle carrying an intermediate
and a root is split first — importing the file whole would silently keep only the first.

### What happens when

- **No CA supplied** (param unresolved, or a controller with a publicly issued certificate, or
  a plain `http://` URL). Nothing is staged, `ca-trust.pem` and `truststore.p12` are removed,
  curl uses the OS store, and the JVM uses the JDK's own `cacerts`. Identical to the app's
  behaviour before the param existed.
- **CA supplied, controller uses it.** `ca-trust.pem` = OS store + chain, `truststore.p12` =
  `cacerts` + chain; both halves verify the controller. This is the case that was failing.
- **CA supplied, controller has a public certificate.** Both trust files are supersets of the
  default, so the controller verifies through the public roots and the extra anchor is simply
  unused.
- **JDK swap** (the controller's Java major version changed). `Get-MatchingJava` /
  `ensure_matching_java` replaces `<agent dir>/java-temurin-<major>`, and the truststore is
  rebuilt from the *new* JDK's `cacerts` immediately afterwards, on that same start.

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

### Linux

Requires root and a Jenkins controller with the Swarm plugin installed:

```bash
sudo env \
  JENKINS_URL=https://jenkins.example.com \
  JENKINS_USERNAME=agent-user \
  JENKINS_PASSWORD=token-or-password \
  sh install-jenkins-agent.sh

# what the generated service runs
sudo env \
  JENKINS_URL=https://jenkins.example.com \
  JENKINS_USERNAME=agent-user \
  LABELS=my-pool \
  TLS_CA_FILE=/path/to/platform-ca.pem \
  sh start-jenkins-agent.sh
```

`TLS_CA_FILE` stands in for what the runtime materializes from the `tls_ca` param.
Leave it out to exercise the no-CA path.

Check the agent in Jenkins under **Build Executor Status**. In another shell, drain it — the
script returns once the agent is offline and idle, and leaves the running agent alone:

```bash
sudo env \
  JENKINS_URL=https://jenkins.example.com \
  JENKINS_USERNAME=agent-user \
  APP_STOP_REASON=terminate \
  sh stop-jenkins-agent.sh
```

### Windows

Requires an administrator shell:

```powershell
$env:JENKINS_URL = 'https://jenkins.example.com'
$env:JENKINS_USERNAME = 'agent-user'
$env:JENKINS_PASSWORD = 'token-or-password'
powershell -File .\install-jenkins-agent.ps1

# what the generated service runs
$env:LABELS = 'my-pool'
$env:TLS_CA_FILE = 'C:\path\to\platform-ca.pem'   # optional; omit for the no-CA path
powershell -File .\start-jenkins-agent.ps1
```

In another shell, drain it:

```powershell
$env:JENKINS_URL = 'https://jenkins.example.com'
$env:JENKINS_USERNAME = 'agent-user'
$env:APP_STOP_REASON = 'terminate'
powershell -File .\stop-jenkins-agent.ps1
```
