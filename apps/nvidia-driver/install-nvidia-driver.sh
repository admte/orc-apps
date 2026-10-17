#!/bin/sh
set -eu

# Installs the NVIDIA driver from the distribution's own packages and gets the
# kernel module loaded, rebooting once when it cannot load in place.
#
# The pass is idempotent, which is what ends the reboot loop: the runtime runs
# this script again from the top after a reboot, and a pass that finds the
# driver loaded, or no NVIDIA GPU at all, is the convergence signal.
#
# Ubuntu only, for now: it publishes the driver with kernel modules built and
# signed for its own kernels, so the driver loads with Secure Boot on and no one
# has to enrol a key at the console during boot — which a node nobody sits at
# cannot do.

note() {
	echo "nvidia-driver install: $*"
}

warn() {
	echo "nvidia-driver install: warning: $*" >&2
}

fail() {
	echo "nvidia-driver install: $*" >&2
	exit 1
}

# Remembers the boot that asked for a reboot, so the pass after it can tell
# "installed, reboot pending" from "rebooted and still not loaded". Overridable
# only so a test can point it somewhere writable.
state_dir=${NVIDIA_DRIVER_STATE_DIR:-/var/lib/nvidia-driver-app}
reboot_marker="$state_dir/reboot-requested"

# NVIDIA display and 3D controllers on the PCI bus, read from sysfs so the
# check needs no pciutils.
nvidia_gpus() {
	count=0
	for dev in /sys/bus/pci/devices/*; do
		[ "$(cat "$dev/vendor" 2>/dev/null)" = 0x10de ] || continue
		case "$(cat "$dev/class" 2>/dev/null)" in
		0x03*) count=$((count + 1)) ;;
		esac
	done
	echo "$count"
}

driver_loaded() {
	command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

boot_id() {
	cat /proc/sys/kernel/random/boot_id
}

# What an operator needs when the driver will not load: Secure Boot, a nouveau
# that kept the GPU, and what the kernel said about the module.
diagnose() {
	if command -v mokutil >/dev/null 2>&1; then
		warn "$(mokutil --sb-state 2>&1 | head -1)"
	fi
	if lsmod | grep -q '^nouveau '; then
		warn "the nouveau driver is loaded and holds the GPU"
	fi
	dmesg 2>/dev/null | grep -iE 'nvidia|nvrm' | tail -5 | while IFS= read -r line; do
		warn "kernel: $line"
	done
}

case "$(uname -s)" in
Linux) ;;
*) fail "supported on Linux only: $(uname -s)" ;;
esac
[ "$(id -u)" -eq 0 ] || fail "must run as root"

gpus=$(nvidia_gpus)
if [ "$gpus" -eq 0 ]; then
	# A pool image is built on a machine without the GPU, so there is no card to
	# pick a driver for. The nodes that boot from it on GPU hardware install the
	# driver on their first pass.
	note "no NVIDIA GPU on this node; nothing to install"
	rm -f "$reboot_marker"
	exit 0
fi

if driver_loaded; then
	version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
	note "driver ${version:-unknown} is loaded for $gpus GPU(s)"
	rm -f "$reboot_marker"
	exit 0
fi

# shellcheck disable=SC1091
[ -r /etc/os-release ] && . /etc/os-release
[ "${ID:-}" = ubuntu ] ||
	fail "supported on Ubuntu only, which publishes the driver with signed kernel modules; this node runs ${PRETTY_NAME:-an unknown distribution}"

# One reboot, not five: if the module did not load after the reboot this install
# asked for, another reboot will not change that, and the node should say why.
if [ -f "$reboot_marker" ] && [ "$(cat "$reboot_marker")" != "$(boot_id)" ]; then
	diagnose
	fail "the driver is installed but did not load after a reboot"
fi

export DEBIAN_FRONTEND=noninteractive
# Ubuntu's needrestart hook reports on stderr after each install, which the
# node log would show as warnings about services nobody asked to restart.
export NEEDRESTART_SUSPEND=1

note "found $gpus NVIDIA GPU(s); installing the driver Ubuntu recommends for them"
apt-get update -qq || fail "could not update the package lists"
if ! command -v ubuntu-drivers >/dev/null 2>&1; then
	apt-get install -y -qq ubuntu-drivers-common || fail "could not install ubuntu-drivers-common"
fi

# --gpgpu is the headless set: driver and compute libraries, none of the
# graphical stack a server never runs. Without --include-dkms the tool only
# considers kernel modules Ubuntu built and signed, so it never leaves an
# unsigned module that Secure Boot would refuse.
ubuntu-drivers install --gpgpu || fail "ubuntu-drivers could not install a driver for this GPU"

# The headless set leaves out the utilities, nvidia-smi among them. Their
# package carries the same branch suffix as the compute library just installed.
compute=$(dpkg-query -W -f '${Package} ${db:Status-Abbrev}\n' 'libnvidia-compute-*' 2>/dev/null |
	awk '$2 == "ii" { print $1 }' | head -1)
[ -n "$compute" ] ||
	fail "no driver was installed: Ubuntu may have no signed kernel module for this kernel ($(uname -r))"
utils="nvidia-utils-${compute#libnvidia-compute-}"
note "installing $utils for nvidia-smi"
apt-get install -y -qq "$utils" || fail "could not install $utils"

# Loading in place works when the module was built for the running kernel and
# nouveau does not hold the GPU. Otherwise — a newer kernel came with the
# module, or nouveau is bound — only a reboot loads it.
if [ -n "$(find "/lib/modules/$(uname -r)" -name 'nvidia.ko*' -print -quit 2>/dev/null)" ] &&
	! lsmod | grep -q '^nouveau '; then
	if modprobe nvidia 2>/dev/null && driver_loaded; then
		version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
		note "driver ${version:-unknown} loaded without a reboot"
		rm -f "$reboot_marker"
		exit 0
	fi
fi

mkdir -p "$state_dir"
boot_id >"$reboot_marker"
note "the driver loads only after a reboot (nouveau holds the GPU, or the module is for a newer kernel); requesting one"
# Plain `shutdown -r now`: under the runtime a shim ahead of this on PATH
# records the request, and the runtime reboots once this pass ends and then
# runs it again. Run by hand, the machine restarts.
shutdown -r now || fail "the driver needs a reboot to load, and the reboot was refused"
note "reboot requested; the install finishes after it"
