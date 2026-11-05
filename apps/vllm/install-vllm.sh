#!/bin/sh
set -eu

# Installs one vLLM release into its own virtual environment and creates the
# account the server runs as. Nothing about the model or port is decided here:
# that belongs to start-vllm.sh, so one install can serve whichever model each
# start asks for.

usage() {
	cat <<'USAGE'
Usage: install-vllm.sh --version=VERSION [--install-root=DIR] [--service-user=NAME]

Installs one vLLM release into its own virtual environment under the install
root, and creates the account the server runs as. Run as root.

  --version=VERSION    vLLM release to install, e.g. 0.11.0
  --install-root=DIR   directory each release is installed under, beside the
                       shared weights cache (default: /opt/vllm)
  --service-user=NAME  account the server runs as (default: vllm)
  --help               show this help
USAGE
}

fail() {
	echo "vllm install: $*" >&2
	exit 1
}

usage_error() {
	echo "vllm install: $*" >&2
	usage >&2
	exit 2
}

version=
root=/opt/vllm
service_user=vllm
for arg; do
	case $arg in
	--version=*) version=${arg#--version=} ;;
	--install-root=*) root=${arg#--install-root=} ;;
	--service-user=*) service_user=${arg#--service-user=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$version" ] || usage_error "--version is required"
[ -n "$root" ] || usage_error "--install-root must not be empty"
[ -n "$service_user" ] || usage_error "--service-user must not be empty"

# Progress goes to stdout and only warnings and errors to stderr, so a healthy
# install writes nothing there.
note() {
	echo "vllm install: $*"
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

# NEEDRESTART_SUSPEND on every apt-get: Ubuntu's needrestart hook reports on
# stderr after each install, which reads as warnings about services nobody asked
# to restart.

# python3 on its own is not enough: Debian and Ubuntu ship it without the piece
# that creates virtual environments, and Alpine without the piece that seeds pip
# into one. Same shape as gcloud's ensure_python and the ensure_unzip in aws,
# terraform and vault — try it, install through whichever package manager the
# machine has, then check again.
#
# Tried rather than asked: `python3 -m venv --help` answers successfully on a
# machine where actually creating one fails.
venv_works() {
	rm -rf "$venv"
	python3 -m venv "$venv" >/dev/null 2>&1
}

ensure_venv() {
	venv_works && return 0
	[ "$(id -u)" -eq 0 ] ||
		fail "python3 cannot create a virtual environment, and installing the package for it needs root"

	note "installing the python3 virtual environment package"
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update -qq
		DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -qq python3-venv
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q python3-pip
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q python3-pip
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive --quiet install python3-pip
	elif command -v apk >/dev/null 2>&1; then
		apk add --no-progress --quiet py3-pip
	else
		fail "python3 cannot create a virtual environment and no supported package manager was found"
	fi
	venv_works ||
		fail "python3 still cannot create a virtual environment after installing the package"
}

# The server compiles kernels when it starts: torch.compile hands its graphs to
# Triton, and Triton builds a small C launcher against the Python headers. A
# fresh server image has neither a C compiler nor the headers, and the only sign
# is an engine that dies at startup with "Failed to find C compiler" — after the
# weights have been downloaded. Checked here, where it is cheap.
python_headers() {
	include=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["include"])' 2>/dev/null) &&
		[ -f "$include/Python.h" ]
}

compiler_works() {
	command -v cc >/dev/null 2>&1 && python_headers
}

ensure_compiler() {
	compiler_works && return 0

	note "installing a C compiler and the Python headers, which the server's kernel compiler needs"
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update -qq
		DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -qq gcc python3-dev
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q gcc python3-devel
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q gcc python3-devel
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive --quiet install gcc python3-devel
	else
		fail "no C compiler or Python headers, and no supported package manager to install them"
	fi
	compiler_works ||
		fail "still no C compiler or Python headers after installing them"
}

case "$(uname -s)" in
Linux) ;;
*) fail "supported on Linux only: $(uname -s)" ;;
esac
case "$(uname -m)" in
x86_64 | amd64 | aarch64 | arm64) ;;
*) fail "vLLM publishes x86-64 and aarch64 wheels; this machine is $(uname -m)" ;;
esac
[ "$(id -u)" -eq 0 ] || fail "must run as root"

need python3
# Checked here and not only in start, so a machine without setpriv fails now
# rather than at the first start.
need setpriv

printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
	fail "invalid version: $version"

prefix="$root/$version"
venv="$prefix/venv"
# Beside the versions rather than inside one: an upgrade, a re-install or a
# repair must not throw away weights that take hours to fetch.
cache="$root/cache"

# The server should not answer the network as root. Created here so start can
# drop to it.
if ! id "$service_user" >/dev/null 2>&1; then
	need useradd
	useradd -r -U -M -s /usr/sbin/nologin "$service_user" ||
		fail "could not create the service user $service_user"
fi

# A GPU is not needed to install, but a machine without one will never serve, and
# finding that out at install time is cheaper than at first request.
if ! command -v nvidia-smi >/dev/null 2>&1; then
	echo "vllm install: warning: nvidia-smi is not on this machine; vLLM will not start without an NVIDIA GPU" >&2
fi

# Install may run again over a version that is already there — a repair, or a
# re-install of the same version — and the server may be running from that
# tree. A finished install is kept and completed in place: the pip
# steps below confirm what is there and add what is missing. Only a tree that
# never finished is thrown away.
done_marker="$prefix/.installed"
if [ -f "$done_marker" ] && [ -x "$venv/bin/vllm" ]; then
	note "completing the existing install at $prefix"
else
	note "creating the virtual environment at $venv"
	rm -rf "$prefix"
	mkdir -p "$prefix"
	# An hour-long install that is interrupted must not leave a half-built tree
	# behind for start to find. The signal trap exits, so the EXIT trap runs once.
	trap 'rm -rf "$prefix"' EXIT
	trap 'rm -rf "$prefix"; exit 1' HUP INT TERM
	ensure_venv
fi
ensure_compiler

# pip verifies every wheel it installs against the hash the index publishes, and
# the version is pinned exactly, so the machine gets the release --version names
# and nothing newer.
note "installing vllm==$version — the wheel and its CUDA payload are gigabytes"
"$venv/bin/pip" install --no-cache-dir --upgrade pip >/dev/null ||
	fail "could not update pip in $venv"
"$venv/bin/pip" install --no-cache-dir "vllm==$version" ||
	fail "could not install vllm==$version"

[ -x "$venv/bin/vllm" ] || fail "the wheel installed no vllm command in $venv/bin"

# FlashInfer, which the server samples and attends with, otherwise compiles its
# kernels with nvcc on first start. The wheels bring an nvcc, but pip resolves
# it independently of the CUDA headers torch pins, and the two drift apart (a
# 13.4 compiler against 13.0 headers refuses to build). FlashInfer publishes
# the same kernels prebuilt for every supported GPU generation, per release and
# CUDA version, so nothing is compiled on the machine and no CUDA toolkit is
# needed. The version is exact, and the local `+cuXYZ` part exists only on
# FlashInfer's index, so the extra index cannot substitute a PyPI package.
flashinfer=$("$venv/bin/pip" show flashinfer-python 2>/dev/null | sed -n 's/^Version: //p')
if [ -n "$flashinfer" ]; then
	cuda=$("$venv/bin/python3" -c 'import torch; print((torch.version.cuda or "").replace(".", ""))' 2>/dev/null) ||
		fail "could not read the CUDA version torch was built for"
	[ -n "$cuda" ] || fail "the torch this release installed has no CUDA build"
	note "installing FlashInfer's prebuilt kernels flashinfer=$flashinfer cuda=cu$cuda"
	"$venv/bin/pip" install --no-cache-dir "flashinfer-jit-cache==$flashinfer+cu$cuda" \
		--extra-index-url "https://flashinfer.ai/whl/cu$cuda" ||
		fail "could not install FlashInfer's prebuilt kernels flashinfer-jit-cache==$flashinfer+cu$cuda"
fi

installed=$("$venv/bin/pip" show vllm 2>/dev/null | sed -n 's/^Version: //p')
[ "$installed" = "$version" ] ||
	fail "installed version '$installed' does not match $version"

chown -R "$service_user:$service_user" "$prefix" ||
	fail "could not give $prefix to $service_user"

# Shared by every installed version, so changing version does not download the
# same model again.
mkdir -p "$cache"
chown "$service_user:$service_user" "$cache" ||
	fail "could not give $cache to $service_user"

# So start-vllm.sh also works without --version. Whichever version was
# installed last is what `current` names.
if [ -e "$root/current" ] && [ ! -L "$root/current" ]; then
	fail "$root/current exists and is not a symlink; remove it and re-install"
fi
ln -sfn "$prefix" "$root/current" || fail "could not point $root/current at $prefix"

: >"$done_marker" || fail "could not mark $prefix as installed"
trap - EXIT HUP INT TERM
note "vllm $installed installed at $prefix"
