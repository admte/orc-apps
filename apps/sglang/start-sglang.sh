#!/bin/sh
set -eu

# Serves one model over SGLang's OpenAI-compatible API. Everything the server is
# told is either the operator's two settings or derived from the node itself.

SERVICE_USER=${SERVICE_USER:-sglang}

fail() {
	echo "sglang start: $*" >&2
	exit 1
}

note() {
	echo "sglang start: $*" >&2
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

# By the version this app instance was installed as: a node may carry two, and
# `current` is whichever was installed last. `current` is the fallback, so the
# package also starts by hand, without the orchestrator setting APP_VERSION.
root=${SGLANG_INSTALL_ROOT:-/opt/sglang}
if [ -n "${APP_VERSION:-}" ] && [ -x "$root/$APP_VERSION/venv/bin/python" ]; then
	prefix="$root/$APP_VERSION"
	version="$APP_VERSION"
else
	prefix="$root/current"
	version=current
fi
python="$prefix/venv/bin/python"
[ -x "$python" ] || fail "no SGLang install found; install must run first path=$python"

# One process per node, using every GPU it may use. The operator is not asked
# how many: the node knows. CUDA_VISIBLE_DEVICES wins where it is set, because
# that is the set the server will actually see.
# Set-but-empty and -1 both mean "no devices" in CUDA's own convention, so the
# test is whether the variable exists, and entries beginning with a minus do not
# count. Getting this wrong would tell the server to use GPUs it cannot see.
if [ "${CUDA_VISIBLE_DEVICES+set}" = set ]; then
	gpus=$(printf '%s' "$CUDA_VISIBLE_DEVICES" | tr ',' '\n' |
		grep -cE '^[[:space:]]*[^-[:space:]]' || true)
else
	need nvidia-smi
	# stderr is left visible: a broken driver should say so rather than be
	# reported as a node with no GPU.
	gpus=$(nvidia-smi -L | grep -c '^GPU ' || true)
fi
[ "$gpus" -ge 1 ] ||
	fail "no NVIDIA GPU visible on this node; SGLang cannot serve without one"

# The endpoint's own port, and it must stay equal to `endpoints.api.port` in
# artifact.yaml: nothing enforces that, and a mismatch shows up only as an
# endpoint that never goes ready.
#
# SGLANG_SERVE_PORT and not SGLANG_PORT: SGLANG_PORT is SGLang's own variable for the
# base of its internal socket range, so reusing it here would move the server
# and walk its private ports onto the same numbers. It is validated because a
# stray value from the surrounding environment — Kubernetes injects
# <SERVICE>_PORT as a tcp:// URI — should say so rather than reach the server.
port=${SGLANG_SERVE_PORT:-30000}
case "$port" in
'' | *[!0-9]*) fail "SGLANG_SERVE_PORT must be a port number, not '$port'" ;;
esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] ||
	fail "SGLANG_SERVE_PORT is out of range: $port"

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
	# A model given as a path on the node is already there: nothing to fetch, and
	# no reason for the server to hold a token it will never use.
	case "$MODEL" in
	/* | ./* | ../*)
		note "the model is a path on this node, so the Hugging Face token is not used"
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
		# readable to every job on this node.
		export HF_TOKEN="$hf_token"
		setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
			env HOME="$prefix" HF_HOME="$HF_HOME" \
			"$downloader" download "$MODEL" >/dev/null ||
			fail "could not fetch $MODEL — check that the token has access to it"
		unset HF_TOKEN
		hf_token=''
	elif [ -n "$hf_token" ]; then
		note "warning: the Hugging Face CLI is missing from the install, so the token has to be passed to the server itself"
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

# [::] and not 0.0.0.0: the probe dials the node's own addresses and, where the
# endpoint is exposed publicly, a pool address that is usually IPv6. A socket
# bound to the IPv4 wildcard has nothing listening for what arrives there.
#
# setpriv, never su or runuser: those start a new session, which would put the
# server outside the process group the runtime signals.
#
# --tp-size and not --tp: the short form is only an argparse abbreviation, which
# stops resolving the day SGLang adds a second option starting with --tp.
exec setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
	env -u HF_TOKEN_FILE HOME="$prefix" HF_HOME="$HF_HOME" \
	"$python" -m sglang.launch_server \
	--model-path "$MODEL" \
	--host '::' \
	--port "$port" \
	--tp-size "$gpus"
