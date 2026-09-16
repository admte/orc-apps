# cpp-dev-tools

Linux-only app that installs a C++ build toolchain using the host package manager.

```text
cpp-dev-tools/
  artifact.yaml
  install-cpp-dev-tools.sh   # install compiler + make via apt/dnf/yum/apk/pacman/zypper
```

No operator parameters — the package list is fixed. This is an install-only package; it does
not define a long-running `start` action.

Supported package managers:

- `apt-get`: `build-essential`
- `dnf` / `yum`: `gcc gcc-c++ make`
- `apk`: `build-base`
- `pacman`: `base-devel`
- `zypper`: `devel_C_C++`

Build + push (from the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`):

```bash
./orc build ./apps/cpp-dev-tools --push
```

Validate locally:

```bash
./orc build ./apps/cpp-dev-tools --output /tmp/cpp-dev-tools-oci
```

Verify toolchain:

```bash
gcc --version
make --version
```
