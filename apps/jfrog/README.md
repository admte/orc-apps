# jfrog

Installs the JFrog CLI so scripts and people on the machine can work with Artifactory and the
rest of the JFrog Platform. Give it a URL, user and token and the CLI is signed in to that
server; leave all three out and the CLI is installed ready for you to configure.

- `jfrog_url` (optional): JFrog Platform URL, e.g. `https://example.jfrog.io`; give all three
  together
- `jfrog_user` (optional): JFrog username
- `jfrog_token` (optional): JFrog access token for that user

Runs on Linux (amd64, arm64), macOS (amd64, arm64) and Windows (amd64).
