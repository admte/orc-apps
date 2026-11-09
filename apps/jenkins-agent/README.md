# jenkins-agent

Turns a machine into a Jenkins agent. It connects to your Jenkins controller, runs your builds
as a system service, and when it is stopped it lets the running build finish first.
The agent is named after the machine.

- `jenkins_url` (required): Jenkins controller URL, e.g. `https://jenkins.example.com`
- `jenkins_username` (required): Jenkins user; needs Agent Create, Connect, Disconnect and
  Overall/RunScripts
- `jenkins_password` (required): API token or password for that user
- `labels` (optional): Labels to give the agent
- `tls_ca` (optional): Extra CA certificates to trust the controller with, in PEM

Runs on Linux (amd64, arm64) and Windows (amd64).
