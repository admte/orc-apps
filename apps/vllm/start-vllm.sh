#!/bin/sh
set -eu

# Serves one model over vLLM's OpenAI-compatible API. Everything the server is
# told is either MODEL and the optional Hugging Face token, or derived from the
# machine itself.

SERVICE_USER=${SERVICE_USER:-vllm}

fail() {
	echo "vllm start: $*" >&2
	exit 1
}

note() {
	echo "vllm start: $*"
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

token_value() {
	if [ -n "${HF_TOKEN_FILE:-}" ]; then
		[ -r "$HF_TOKEN_FILE" ] ||
			fail "HF_TOKEN_FILE is set but cannot be read: $HF_TOKEN_FILE"
		tr -d '\r\n' <"$HF_TOKEN_FILE"
	elif [ -n "${HF_TOKEN:-}" ]; then
		printf '%s' "$HF_TOKEN"
	else
		echo ''
	fi
}

need setpriv

[ -n "${MODEL:-}" ] || fail "MODEL is required"

# By APP_VERSION, the version to serve: a machine may carry two, and `current`
# is whichever was installed last. `current` is the fallback, so this script
# also starts without APP_VERSION set.
root=${VLLM_INSTALL_ROOT:-/opt/vllm}
if [ -n "${APP_VERSION:-}" ] && [ -x "$root/$APP_VERSION/venv/bin/vllm" ]; then
	prefix="$root/$APP_VERSION"
	version="$APP_VERSION"
else
	prefix="$root/current"
	version=current
fi
server="$prefix/venv/bin/vllm"
[ -x "$server" ] || fail "no vLLM install found; install must run first path=$server"

# One process per machine, using every GPU it may use. Nobody is asked how many:
# the machine knows. CUDA_VISIBLE_DEVICES wins where it is set, because that is
# the set the server will actually see.
# Set-but-empty and -1 both mean "no devices" in CUDA's own convention, so the
# test is whether the variable exists, and entries beginning with a minus do not
# count. Getting this wrong would tell the server to use GPUs it cannot see.
if [ "${CUDA_VISIBLE_DEVICES+set}" = set ]; then
	gpus=$(printf '%s' "$CUDA_VISIBLE_DEVICES" | tr ',' '\n' |
		grep -cE '^[[:space:]]*[^-[:space:]]' || true)
else
	need nvidia-smi
	# stderr is left visible: a broken driver should say so rather than be
	# reported as a machine with no GPU.
	gpus=$(nvidia-smi -L | grep -c '^GPU ' || true)
fi
[ "$gpus" -ge 1 ] ||
	fail "no NVIDIA GPU visible on this machine; vLLM cannot serve without one"

# The port the API listens on. Its default must stay equal to the port that
# artifact.yaml beside this script declares: nothing enforces that, and a
# mismatch shows up only as an API that never answers where it is expected.
#
# VLLM_SERVE_PORT and not VLLM_PORT: VLLM_PORT is vLLM's own variable for the
# base of its internal socket range, so reusing it here would move the server
# and walk its private ports onto the same numbers. It is validated because a
# stray value from the surrounding environment — Kubernetes injects
# <SERVICE>_PORT as a tcp:// URI — should say so rather than reach the server.
port=${VLLM_SERVE_PORT:-8000}
case "$port" in
'' | *[!0-9]*) fail "VLLM_SERVE_PORT must be a port number, not '$port'" ;;
esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] ||
	fail "VLLM_SERVE_PORT is out of range: $port"

hf_token=$(token_value)
if [ -n "$hf_token" ]; then token_given=1; else token_given=0; fi

# Shared by every installed version, so changing version does not re-download
# the model, and a restart reuses what the first start fetched.
HF_HOME="$root/cache"
export HF_HOME

# Printed, not checked against a threshold: how much room a model needs is the
# model's business. But a start that runs out of disk halfway through a download
# should be one line to diagnose instead of a traceback.
if avail=$(df -Pk "$HF_HOME" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }'); then
	[ -z "$avail" ] || note "weights cache $HF_HOME has ${avail} GiB free"
fi

# A gated model is fetched here, before the server starts, so that the token is
# spent on the download and never reaches the environment of the long-lived
# process — which is the one that later runs whatever the model is asked to do.
if [ -n "$hf_token" ]; then
	# A model given as a path on the machine is already there: nothing to fetch, and
	# no reason for the server to hold a token it will never use.
	case "$MODEL" in
	/* | ./* | ../*)
		note "the model is a path on this machine, so the Hugging Face token is not used"
		hf_token=''
		downloader=''
		;;
	*)
		# `hf` is the current name of the Hugging Face CLI and `huggingface-cli`
		# the older one; which one the install has depends on the hub version
		# this release pulled in, so take whichever is there.
		downloader=''
		for candidate in hf huggingface-cli; do
			if [ -x "$prefix/venv/bin/$candidate" ]; then
				downloader="$prefix/venv/bin/$candidate"
				break
			fi
		done
		;;
	esac
	if [ -n "$downloader" ]; then
		note "fetching the weights for a gated model before starting model=$MODEL"
		# Exported, never written as an argument. `env NAME=value` would put the
		# token in the argv of env and setpriv, and /proc/<pid>/cmdline is world
		# readable to every process on this machine.
		export HF_TOKEN="$hf_token"
		setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
			env HOME="$prefix" HF_HOME="$HF_HOME" \
			"$downloader" download "$MODEL" >/dev/null ||
			fail "could not fetch $MODEL — check that the token has access to it"
		unset HF_TOKEN
		hf_token=''
	elif [ -n "$hf_token" ]; then
		echo "vllm start: warning: the Hugging Face CLI is missing from the install, so the token has to be passed to the server itself" >&2
	fi
fi

# Said plainly here, because otherwise the only sign is a download failing deep
# inside the server with a permission error from the hub.
if [ "$token_given" -eq 0 ]; then
	case "$MODEL" in
	/* | ./* | ../*) : ;;
	*) note "no Hugging Face token was given: this works for a public model and fails for a gated or private one" ;;
	esac
fi

note "serving model=$MODEL port=$port gpus=$gpus version=$version"
case "$MODEL" in
/* | ./* | ../*) : ;;
*) note "the first start downloads the weights, which takes as long as the model is large" ;;
esac

# Exported rather than spliced into the command line, for the same reason as
# above; on this path the server does keep it, which the README calls out.
if [ -n "$hf_token" ]; then
	export HF_TOKEN="$hf_token"
else
	unset HF_TOKEN 2>/dev/null || true
fi

# [::] and not 0.0.0.0, so the server also answers on the machine's IPv6
# addresses: a socket bound to the IPv4 wildcard has nothing listening for what
# arrives there.
#
# setpriv, never su or runuser: those start a new session, which would take the
# server out of this script's process group, so a signal sent to the group would
# miss it.
exec setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
	env -u HF_TOKEN_FILE HOME="$prefix" HF_HOME="$HF_HOME" \
	"$server" serve "$MODEL" \
	--host '::' \
	--port "$port" \
	--tensor-parallel-size "$gpus"
