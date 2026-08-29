#!/usr/bin/env bash
# Build NVIDIA's open kernel module from source against the kernel this image
# actually runs.
#
# This used to pull UBlue's akmods bundle, which cannot work on a Hummingbird
# base. UBlue publishes akmods per exact kernel NEVR, and it builds none for
# Hummingbird's kernel: ghcr.io/ublue-os/akmods-nvidia-open has no tag
# containing 7.1.8 at all -- its newest coreos-stable is
# coreos-stable-44-7.0.9-205.fc44 -- so the derived tag
# coreos-stable-43-7.1.8-100.fc43.x86_64 resolved to nothing and skopeo failed
# with "reading manifest ... unknown". public-hummingbird ships no nvidia
# package either: of its 3,510 packages, zero match nvidia or akmod.
#
# So there is no prebuilt module for this base, and the only remaining source
# is NVIDIA's own. The base image does carry the build tree this needs --
# /usr/lib/modules/<kernel>/build is present in
# quay.io/hummingbird-community/bootc-os.
#
# Consequence worth stating plainly: the akmods bundle also supplied the
# userspace RPMs (nvidia-driver, nvidia-driver-cuda, nvidia-container-toolkit).
# A .run install provides the same userspace as files rather than as those RPM
# names, so the contract check asserts the module and driver binaries instead.
# nvidia-container-toolkit has no source here at all and is genuinely dropped.
set -euo pipefail

flavor="$1"
DNF="$(command -v dnf5 || command -v dnf)"

# NVIDIA's own designation of the current driver, not a hand-picked directory
# listing: https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt
driver_version="${UTAH_NVIDIA_DRIVER_VERSION:-595.84}"
run="NVIDIA-Linux-x86_64-${driver_version}.run"
url="https://download.nvidia.com/XFree86/Linux-x86_64/${driver_version}/${run}"

kernel="$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -n1)"
build_tree="/usr/lib/modules/${kernel}/build"
if [ ! -d "$build_tree" ]; then
  echo "No kernel build tree at $build_tree; cannot build the NVIDIA module" >&2
  exit 1
fi

"$DNF" -y install gcc make kmod

curl --retry 3 --retry-all-errors -fsSLo "/tmp/${run}" "$url"
sh "/tmp/${run}" --extract-only --target /tmp/nvidia-source

build_module() {
  # $1: kernel release whose build tree to compile against
  local release="$1" tree="/usr/lib/modules/$1/build"
  test -d "$tree"
  make -C "$tree" M=/tmp/nvidia-source/kernel-open modules
  install -d "/usr/lib/modules/${release}/extra/nvidia"
  find /tmp/nvidia-source/kernel-open -name 'nvidia*.ko' \
    -exec install -m0644 -t "/usr/lib/modules/${release}/extra/nvidia" {} +
  depmod -a "$release"
  # Leave the tree clean so the next kernel does not link against these.
  make -C "$tree" M=/tmp/nvidia-source/kernel-open clean
}

build_module "$kernel"

# Userspace: the same payload, installed without touching the kernel module,
# the initramfs, or the running system's X configuration.
sh "/tmp/${run}" --silent --no-kernel-module --no-nouveau-check \
  --no-rebuild-initramfs --no-backup --install-libglvnd

install -d /usr/lib/bootc/kargs.d /usr/lib/modprobe.d
printf '%s\n' 'blacklist nouveau' 'options nouveau modeset=0' >/usr/lib/modprobe.d/00-nouveau-blacklist.conf
printf '%s\n' 'kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]' >/usr/lib/bootc/kargs.d/00-nvidia.toml
printf '%s\n' "$driver_version" >/usr/lib/utah/nvidia-driver-version

if [[ "$flavor" == nvidia-gaming ]]; then
  # The OGC kernel is a second target: its tree was preserved by
  # install-ogc-kernel.sh precisely so this module can be built against it.
  ogc_release="$(cat /usr/lib/utah/ogc-kernel-release)"
  build_module "$ogc_release"
fi

rm -rf "/tmp/${run}" /tmp/nvidia-source
"$DNF" -y remove gcc make
"$DNF" clean all
