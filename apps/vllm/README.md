# vllm

Serves a large language model from the machine through an OpenAI-compatible API on port 8000, so
anything that talks to OpenAI can use your own model. vLLM spreads the model across every GPU the
machine has. It needs an NVIDIA GPU with its driver installed; this app does not install the driver.

- `model` (required): Hugging Face model, e.g. `meta-llama/Llama-3.1-8B-Instruct`, or a path on the
  machine
- `hf_token` (optional): Hugging Face read token, needed only for a gated or private model

Runs on Linux (amd64, arm64).
