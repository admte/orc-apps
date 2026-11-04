# Working in this repository

## App versions

An app's version is the version of the software it installs, never of its manifest or scripts.

- An app that installs a fixed upstream release carries that release's version
  (`org.opencontainers.image.version`), and a new upstream release is a new app version.
- An app that always installs the latest upstream build (github-runner, uv, node, …) carries **no
  version**: it publishes as `<app>:default` only.
- Changing a manifest or a script (a new manifest format, a bug fix, new params) is never a reason
  to add or bump a version. It republishes the same tag.
