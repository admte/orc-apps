# shell

Multi-platform app that runs an arbitrary command. Defined by a single `artifact.yaml`;
platform differences (`cmd` media type, `start.command`) come from `platforms[].vars`.

```text
shell/
  artifact.yaml    # linux/amd64 + windows/amd64
```

| Platform | `cmd` param syntax |
|----------|-------------------|
| linux/amd64 | POSIX shell (`text/x-sh`) |
| windows/amd64 | cmd.exe (`text/plain`) |

Build + push (from the repo root, after `./scripts/install.sh` and `./orc login ghcr.io`):

```bash
./orc build ./apps/shell --push
```

Override the version tag:

```bash
./orc build ./apps/shell --tag shell:1.0.1,default --push
```
