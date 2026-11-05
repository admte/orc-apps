#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: start-codex.sh [--api-key-file=PATH] [--install-dir=DIR]

Checks that the Codex CLI runs and, given a key file, signs it in with the
OpenAI API key.

  --api-key-file=PATH  file holding the OpenAI API key
  --install-dir=DIR    where install put the codex command (default: /usr/local/bin)
  --help               show this help
USAGE
}

fail() {
	echo "codex configure: $*" >&2
	exit 1
}

usage_error() {
	echo "codex configure: $*" >&2
	usage >&2
	exit 2
}

key_file=
install_dir=/usr/local/bin
for arg; do
	case $arg in
	--api-key-file=*) key_file=${arg#--api-key-file=} ;;
	--install-dir=*) install_dir=${arg#--install-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

if command -v codex >/dev/null 2>&1; then
	codex_bin=$(command -v codex)
elif [ -x "$install_dir/codex" ]; then
	codex_bin=$install_dir/codex
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/codex" ]; then
	codex_bin=$HOME/.local/bin/codex
else
	fail "Codex CLI is not installed"
fi
if [ -n "${CODEX_HOME:-}" ]; then
	umask 077
	mkdir -p "$CODEX_HOME"
fi
"$codex_bin" --version >/dev/null

if [ -z "$key_file" ]; then
	echo "Codex CLI is ready; OpenAI API key was not provided" >&2
	exit 0
fi
[ -r "$key_file" ] || fail "the API key file is not readable"
[ -s "$key_file" ] || fail "openai_api_key is empty"

umask 077
"$codex_bin" login --with-api-key <"$key_file"
"$codex_bin" login status >/dev/null
echo "Codex CLI API key configured" >&2
