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
#
# Neither the driver download nor the module compile depends on anything this
# image does, so both are hoisted into the cache image built from
# Containerfile.kernel (see `just kernel-cache-tag`) and reused here.  The
# userspace install is deliberately *not* cached: it runs the vendor installer
# over a populated /usr, and it has to keep happening after the package
# transaction rather than before it.  With no cache present -- a local
# `just build`, or the cache image's own build -- everything below falls through
# to building from source.
set -euo pipefail

flavor="$1"
DNF="$(command -v dnf5 || command -v dnf)"
CACHE_DIR="${UTAH_KERNEL_CACHE_DIR:-/utah-cache}"
# Set when this is the cache image building its own contents: compile the
# modules, archive them, and stop short of installing the userspace.
modules_only="${UTAH_NVIDIA_MODULES_ONLY:-}"

# NVIDIA's own designation of the current driver, not a hand-picked directory
# listing: https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt
driver_version="${UTAH_NVIDIA_DRIVER_VERSION:-595.84}"
run="NVIDIA-Linux-x86_64-${driver_version}.run"
url="https://download.nvidia.com/XFree86/Linux-x86_64/${driver_version}/${run}"

ogc_release=""
[ -f /usr/lib/utah/ogc-kernel-release ] && ogc_release="$(cat /usr/lib/utah/ogc-kernel-release)"

# `kernel` is a metapackage.  A bootc base may well carry kernel-core without
# it, in which case this query returns nothing and every path below silently
# refers to /usr/lib/modules//build.  The module trees on disk are the ground
# truth, so fall back to them -- excluding the OGC kernel, which is installed by
# the time this runs and is a separate target rather than the base one.
kernel="$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | tail -n1 || true)"
if [ -z "$kernel" ] || [ ! -d "/usr/lib/modules/${kernel}/build" ]; then
  kernel="$(for d in /usr/lib/modules/*/; do
              d="${d%/}"; d="${d##*/}"
              [ "$d" = "$ogc_release" ] && continue
              [ -d "/usr/lib/modules/$d/build" ] && echo "$d"
            done | sort -V | tail -n1)"
  echo "rpm named no usable kernel; using the module tree on disk: ${kernel:-none}"
fi

build_tree="/usr/lib/modules/${kernel}/build"
if [ -z "$kernel" ] || [ ! -d "$build_tree" ]; then
  echo "No kernel build tree at $build_tree; cannot build the NVIDIA module" >&2
  exit 1
fi

"$DNF" -y install gcc make kmod

if [ -f "${CACHE_DIR}/nvidia-installer.run" ]; then
  run_path="${CACHE_DIR}/nvidia-installer.run"
else
  run_path="/tmp/${run}"
  curl --retry 3 --retry-all-errors -fsSLo "$run_path" "$url"
fi
# Unpacking the installer is only needed in order to compile, so do it on
# demand: when every module comes from the cache, this never runs.
ensure_source() {
  [ -d /tmp/nvidia-source ] || sh "$run_path" --extract-only --target /tmp/nvidia-source
}

build_module() {
  # $1: kernel release whose module to provide.  Prefers the archive the cache
  # image built for exactly this release; compiles it when there is none.
  local release="$1" tree="/usr/lib/modules/$1/build"
  local cached="${CACHE_DIR}/nvidia-modules-${release}.tar"
  if [ -f "$cached" ]; then
    echo "Unpacking the prebuilt NVIDIA module for ${release}"
    tar -C / -xf "$cached"
  else
    test -d "$tree"
    ensure_source
    # The compile was serial, which cost minutes per kernel for no reason.
    make -j"$(nproc)" -C "$tree" M=/tmp/nvidia-source/kernel-open modules
    install -d "/usr/lib/modules/${release}/extra/nvidia"
    find /tmp/nvidia-source/kernel-open -name 'nvidia*.ko' \
      -exec install -m0644 -t "/usr/lib/modules/${release}/extra/nvidia" {} +
    # Leave the tree clean so the next kernel does not link against these.
    make -C "$tree" M=/tmp/nvidia-source/kernel-open clean
  fi
  depmod -a "$release"
  if [ -n "${UTAH_KERNEL_CACHE_OUT_DIR:-}" ]; then
    tar -C / -cf "${UTAH_KERNEL_CACHE_OUT_DIR}/nvidia-modules-${release}.tar" \
      "usr/lib/modules/${release}/extra/nvidia"
  fi
}

build_module "$kernel"

if [ -n "$modules_only" ]; then
  if [[ "$flavor" == *gaming ]]; then
    build_module "${ogc_release:?}"
  fi
  cp -f "$run_path" "${UTAH_KERNEL_CACHE_OUT_DIR:?}/nvidia-installer.run"
  rm -rf /tmp/nvidia-source
  exit 0
fi

# Userspace: the same payload, installed without touching the kernel module,
# the initramfs, or the running system's X configuration.
sh "$run_path" --silent --no-kernel-module --no-nouveau-check \
  --no-rebuild-initramfs --no-backup --install-libglvnd

install -d /usr/lib/bootc/kargs.d /usr/lib/modprobe.d
printf '%s\n' 'blacklist nouveau' 'options nouveau modeset=0' >/usr/lib/modprobe.d/00-nouveau-blacklist.conf
printf '%s\n' 'kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]' >/usr/lib/bootc/kargs.d/00-nvidia.toml
printf '%s\n' "$driver_version" >/usr/lib/utah/nvidia-driver-version

if [[ "$flavor" == nvidia-gaming ]]; then
  # The OGC kernel is a second target: its tree was preserved by
  # install-ogc-kernel.sh precisely so this module can be built against it.
  build_module "${ogc_release:?}"
fi

rm -rf "/tmp/${run}" /tmp/nvidia-source
"$DNF" -y remove gcc make
"$DNF" clean all
