# vllm

Runs a [vLLM](https://github.com/vllm-project/vllm) inference server on the
node, serving one model over an OpenAI-compatible HTTP API.

## Settings

| Setting | Required | Description |
|---------|----------|-------------|
| `model` | yes | Hugging Face model to serve, for example `meta-llama/Llama-3.1-8B-Instruct`, or a path on the node |
| `hf_token` | no | Only for a gated or private model. Created under *Settings > Access Tokens* with read access. |

Two settings, one of them optional, and that is the whole form. Everything else
the server needs the node already knows:

- **The port** is the endpoint's, declared in the manifest. There is no setting
  for it, because where this app listens is the package's decision, not the
  operator's. Running the package by hand, `VLLM_SERVE_PORT` moves it — and
  not `VLLM_PORT`, which is the server's own variable for the base of its
  internal socket range.
- **Tensor parallelism** is the number of GPUs the node may use — the entries in
  `CUDA_VISIBLE_DEVICES` where that is set, otherwise what `nvidia-smi` reports.
  Asking the operator would be asking them to describe hardware the node can
  describe itself.
- **Everything else** — data type, context length, memory fraction,
  quantisation — is vLLM's own default. Adding one of these as a setting later
  is free; removing a setting once pools are running on it is not, which is why
  none of them is here yet.

## The endpoint

```yaml
endpoints:
  api:
    port: 8000
    protocol: http
    probe:
      http: /health
    serve: spread
```

`/health` is the path vLLM's own deployment guide probes. It is worth being
precise about what it does for us: vLLM builds the engine before it starts the
HTTP server, so during the minutes a large model takes to load there is no
listener at all and the probe fails on the dial. Either way the node takes no
traffic until it can actually serve, which is the point.

`spread` because every node holds its own copy of the same model and any of them
can answer any request. Nothing is kept on one node, so there is no reason to
send traffic to one.

The server binds `[::]`, the dual-stack wildcard. An app bound to `127.0.0.1`
never passes its probe, and one bound to `0.0.0.0` fails the moment the endpoint
is exposed publicly, because pool addresses are usually IPv6.

## Calling it

The endpoint speaks the OpenAI API, so anything that talks to OpenAI talks to
this. From anywhere that can reach the pool:

```bash
curl http://<pool-address>:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "meta-llama/Llama-3.1-8B-Instruct",
       "messages": [{"role": "user", "content": "Hello"}]}'
```

The `model` field in the request is the same string that was typed into the
app's **Model** setting; `GET /v1/models` lists it if you are unsure. An OpenAI
client library works against this the same way, with its base URL set to
`http://<pool-address>:8000/v1` and any value as the API key — none is
checked, because none is configured.

## Versioning

`config.versions` reads the project's GitHub releases, the same source
`terraform` uses. Unlike the environment-preparing apps in this catalog, the
version here is the operator's to choose and nobody else's: this app *is* the
server, and vLLM releases differ in the models they support, the CUDA they need
and the performance they give.

There is one deliberate departure from the other catalog apps: no
`latest_per: minor`. For a toolchain the minor is the release axis, so keeping
the newest patch of each is right. For a server it is the patches that carry the
model support and the fixes, so the list is simply the thirty most recent
releases.

The install pins the version exactly — `pip install vllm==<version>` — so a node
gets the release that was chosen and nothing newer.

## The Hugging Face token

A gated model needs one. The start phase spends it before the server starts: it
downloads the weights with the Hugging Face CLI — `hf`, or `huggingface-cli` on
an older hub — and then execs the server **without** the token in its
environment. The server has no use for it afterwards, and it has no business in
the environment of a long-lived process that runs whatever the model is asked to
do.

The token is never written as a command-line argument either, for the download
or the server. `/proc/<pid>/cmdline` is readable by every job on the node.

A model given as a path on the node needs no token at all, and the token is
dropped in that case rather than handed to the server.

## Where the weights live

In one cache under `/opt/vllm/cache`, shared by every installed version. A
restart reuses what the first start downloaded, a re-install or a repair does
not throw it away, and changing version does not fetch the same model again.
Uninstalling one version leaves it; uninstalling the last one removes it.

## Lifecycle

- **install** creates a virtual environment under `/opt/vllm/<version>`,
  installs that exact release into it, creates the `vllm` account the server
  runs as, and points `/opt/vllm/current` at it. It decides nothing about this
  node: no model, no port. A pool bake runs this phase alone and snapshots the
  disk, so anything node-specific would be shared by every clone. An interrupted
  install cleans up after itself rather than leaving a half-built tree.
- **start** counts the GPUs, fetches a gated model if a token was given, and
  execs the server as the `vllm` account. It uses the version it was installed
  as, falling back to `current` — so the package also starts by hand, with no
  orchestrator to set `APP_VERSION`. It is a runtime-managed service, so it
  survives an agent restart, and `restart: on-failure` brings it back if the
  server itself dies.
- **stop** is the default `SIGTERM` with a 60-second grace, because unloading a
  large model off the GPUs takes longer than the default ten seconds. There is
  no stop command: requests here last seconds, so there is nothing to drain.
- **uninstall** removes `/opt/vllm/<version>`, and the shared cache with it when
  it was the last version installed. The service account is left, since another
  installed version may still be running as it.

## Requirements

- **An NVIDIA GPU**, and the driver for it. The install phase warns when
  `nvidia-smi` is missing; the start phase refuses outright, because a node
  without a GPU can never serve.
- **Linux on x86-64 or aarch64.** vLLM publishes manylinux wheels for both.
- **Root**, for every phase, plus `useradd` and `setpriv` (util-linux 2.31 or
  newer, for `--init-groups`). Install checks for `setpriv` so a bake cannot
  produce an image that only fails at first boot.
- **`python3`.** The package that lets it create virtual environments is not
  everywhere — Debian and Ubuntu leave it out, Alpine leaves out the part that
  seeds pip. Install fetches it through apt-get, dnf, yum, zypper or apk, the
  same way `gcloud` fetches python3 and `aws`, `terraform` and `vault` fetch
  `unzip`. A fresh node needs no preparation.
- **Outbound HTTPS** to PyPI at install, and to `huggingface.co` at first start.
- **Disk.** The wheel and its CUDA payload are several gigabytes; the weights are
  as large as the model.

## Limitations

- **The first start is slow, and looks like a failure if you do not expect it.**
  Downloading and loading a large model takes minutes, and the endpoint stays
  unready until it finishes. The probe covers this — the node simply does not
  receive traffic yet.
- **Tensor parallelism is the GPU count, and some models refuse some counts.**
  A model's attention heads must divide by it; on a node with, say, three GPUs a
  model that needs a power of two will not start. The failure is loud and comes
  from vLLM. Use a pool whose nodes carry a suitable number of GPUs, or restrict
  the set with `CUDA_VISIBLE_DEVICES`.
- **One model per app.** Serving a second model on the same node means a second
  assignment, and the two would want the same port and the same GPUs.
- **A public endpoint has no authentication of its own.** vLLM can require an
  API key, but that is not wired up here: who may reach the endpoint is the
  deployment's decision, not the package's.
- **The token is spent at start, not stored.** If the Hugging Face CLI is missing
  from the install, the script says so and falls back to passing the token to
  the server, where jobs running on that node could read it from the
  environment.
- **The whole model repository is fetched**, not only the files vLLM loads. For
  repositories that ship several checkpoint formats that is more disk and more
  download than the server needs.
- **A node booted with `ipv6.disable=1`** cannot open the `[::]` socket at all,
  and the server will not start on it.

## Build

```bash
./orc build ./apps/vllm --output /tmp/vllm-oci
```
