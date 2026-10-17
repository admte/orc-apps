# nvidia-driver

Installs the NVIDIA GPU driver on an Ubuntu node from Ubuntu's own packages, and
gets the kernel module loaded — rebooting the node once when it cannot load in
place. Put it before any app that needs the GPU, such as `vllm` or `sglang`, and
after `os-update` when the pool has one, so the driver is installed for the
kernel the node will keep.

## Settings

None. `ubuntu-drivers` picks the driver branch, and the open or proprietary
kernel module, for the GPU it finds — the choice an operator would otherwise
look up per card. A branch setting can be added later; removing one would not
be free.

## What one pass does

1. **No NVIDIA GPU on the node:** nothing to do, and the pass succeeds. The app
   in a pool of machines without GPUs costs nothing. A pool image is built on
   the pool's own kind of machine, so a GPU pool's image is built with the GPU
   present and carries the driver.
2. **The driver is loaded** (`nvidia-smi` lists the GPUs): nothing to do. A node
   that already has a working driver keeps it, whichever branch it is.
3. Otherwise it runs `ubuntu-drivers install --gpgpu`, the headless set — the
   driver and the compute libraries without the graphical stack — and adds the
   matching `nvidia-utils` package for `nvidia-smi`.
4. It loads the module in place when it was built for the running kernel and
   nouveau does not hold the GPU. Otherwise it asks for a reboot, and the pass
   after the reboot finds the driver loaded.

If the module still does not load after that one reboot, the install fails and
the node log says what it found: the Secure Boot state, whether nouveau holds
the GPU, and what the kernel said about the module. Another reboot would not
change any of it.

## Secure Boot

Ubuntu builds and signs the kernel modules for its own kernels, and
`ubuntu-drivers` only considers those unless it is asked for DKMS. So the driver
loads with Secure Boot on, and nobody has to enrol a key at the console during
boot — which a node nobody sits at cannot do. A kernel Ubuntu has no signed
module for gets no driver, and the install fails saying so.

## Requirements

- **Ubuntu**, on x86-64 or aarch64. Other distributions fail with that reason.
- **Root**, which every install phase has.
- **Outbound HTTPS** to the Ubuntu archive.

## Limitations

- **Removing the app leaves the driver installed.** The driver belongs to the
  machine, and other apps on it may still be using the GPU.
- **It does not change a working driver.** A node whose driver loads is left as
  it is, even when Ubuntu now recommends a newer branch.
- **The reboot is the node's.** Every app on the node stops for it, the same as
  for `os-update`.

## Build

```bash
./orc build ./apps/nvidia-driver --output /tmp/nvidia-driver-oci
```
