# nvidia-driver

Gets an NVIDIA GPU working on an Ubuntu machine: installs the driver Ubuntu recommends for the
card, signed so it loads with Secure Boot on, and reboots the machine once if the driver cannot
load without it. A machine with no NVIDIA GPU, or with a working driver already, is left as it
is.

It needs no settings.

Runs on Ubuntu Linux (amd64, arm64).
