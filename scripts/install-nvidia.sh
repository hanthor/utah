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
# is NVIDIA's own.
#
# This used to claim the base image carries the build tree needed for that. It
# does not, and the claim had never been executed: run 33253331819 reached this
# script for the first time and found no /usr/lib/modules/<kernel>/build at all,
# for any kernel. That directory comes from kernel-devel, which a bootc base has
# no reason to ship. It is installed below, and removed again afterwards.
#
# Consequence worth stating plainly: the akmods bundle also supplied the
# userspace RPMs (nvidia-driver, nvidia-driver-cuda, nvidia-container-toolkit).
# A .run install provides the same userspace as files rather than as those RPM
# names, so the contract check asserts the module and driver binaries instead.
#
# nvidia-container-toolkit is the exception, and an earlier version of this
# comment was wrong about it. It said the package had no source here at all,
# reasoning from the akmods bundle being unusable. That does not follow, and
# NVIDIA publishes it directly; it is installed below.
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

# Identify the base kernel from the module trees on disk. The base does carry a
# `kernel` package -- kernel-7.1.8-100.fc43.x86_64 -- so an rpm query would work
# here, but the trees are the ground truth and cost nothing to read. The OGC
# kernel is excluded: it is installed by the time this runs and is a separate
# target, handled at the end.
kernel="$(for d in /usr/lib/modules/*/; do
            d="${d%/}"; d="${d##*/}"
            [ "$d" = "$ogc_release" ] || echo "$d"
          done | sort -V | tail -n1)"

diagnose() {
  echo "--- /usr/lib/modules" >&2; ls -1 /usr/lib/modules >&2 || true
  echo "--- installed kernel packages" >&2; rpm -qa "kernel*" | sort >&2 || true
  echo "--- ogc release: ${ogc_release:-none}, base kernel: ${kernel:-none}" >&2
}

if [ -z "$kernel" ]; then
  echo "No base kernel module tree found; cannot build the NVIDIA module" >&2
  diagnose
  exit 1
fi

# The module build tree comes from kernel-devel, which a bootc base has no
# reason to ship -- and this one does not, which is what took out the first
# attempt at a source build. It is needed only to compile against, so it goes in
# here and comes out again below.
#
# It is not in the repositories this image enables either. The base kernel is a
# Fedora 43 build, 7.1.8-100.fc43, and we pair Hummingbird with Fedora 44:
#
#   No match for argument: kernel-devel-7.1.8-100.fc43.x86_64
#
# Adding the Fedora 43 repository would not fix it for long, because a
# repository only carries the current kernel and this image is pinned to a base
# whose kernel will not move. Fedora own build system keeps every build
# indefinitely, so that is where this comes from, addressed by exact NEVR.
#
# Those RPMs are unsigned at that path, so the download is checked against a
# hash recorded here instead. It is a constant because the base image is pinned
# by digest: the kernel cannot change without BASE_IMAGE changing.
KERNEL_DEVEL_SHA256="${UTAH_KERNEL_DEVEL_SHA256:-b2b504c42b94875af88d666d64ca91000ff30439e74157723a188f54ceebc5ca}"

build_tree="/usr/lib/modules/${kernel}/build"
installed_kernel_devel=""
if [ ! -d "$build_tree" ]; then
  echo "No build tree at $build_tree; supplying kernel-devel-${kernel}"
  if "$DNF" -y install "kernel-devel-${kernel}"; then
    installed_kernel_devel="kernel-devel-${kernel}"
  else
    arch="${kernel##*.}"; nv="${kernel%.*}"; ver="${nv%%-*}"; rel="${nv#*-}"
    koji="https://kojipkgs.fedoraproject.org/packages/kernel/${ver}/${rel}/${arch}"
    rpmfile="kernel-devel-${ver}-${rel}.${arch}.rpm"
    echo "Not in the enabled repositories; taking it from ${koji}/${rpmfile}"
    curl --retry 3 --retry-all-errors -fsSLo "/tmp/${rpmfile}" "${koji}/${rpmfile}"
    actual="$(sha256sum "/tmp/${rpmfile}" | cut -d" " -f1)"
    if [ "$actual" != "$KERNEL_DEVEL_SHA256" ]; then
      echo "kernel-devel SHA-256 is $actual, expected $KERNEL_DEVEL_SHA256" >&2
      echo "The base image kernel has moved; update KERNEL_DEVEL_SHA256." >&2
      exit 1
    fi
    "$DNF" -y install "/tmp/${rpmfile}"
    installed_kernel_devel="kernel-devel"
    rm -f "/tmp/${rpmfile}"
  fi
fi
if [ ! -d "$build_tree" ]; then
  echo "Still no kernel build tree at $build_tree after installing kernel-devel;" >&2
  echo "the NVIDIA module cannot be compiled against the kernel this image boots." >&2
  diagnose
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

# Container GPU access. This was written off as unavailable, on the grounds that
# it came from UBlue akmods bundle and that bundle cannot be used here. The
# bundle was one source, not the only one: NVIDIA publishes the toolkit itself,
# from a path with no distribution version in it, and its dependencies are base
# OS libraries Hummingbird already has. See packages/nvidia-container.repo.
"$DNF" -y install nvidia-container-toolkit

# /usr/lib/utah is created by install-ogc-kernel.sh, but that only runs on the
# gaming flavors, so on plain nvidia nothing has made it yet.
install -d /usr/lib/bootc/kargs.d /usr/lib/modprobe.d /usr/lib/utah
printf '%s\n' 'blacklist nouveau' 'options nouveau modeset=0' >/usr/lib/modprobe.d/00-nouveau-blacklist.conf
printf '%s\n' 'kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]' >/usr/lib/bootc/kargs.d/00-nvidia.toml
printf '%s\n' "$driver_version" >/usr/lib/utah/nvidia-driver-version

if [[ "$flavor" == nvidia-gaming ]]; then
  # The OGC kernel is a second target: its tree was preserved by
  # install-ogc-kernel.sh precisely so this module can be built against it.
  build_module "${ogc_release:?}"
fi

rm -rf "/tmp/${run}" /tmp/nvidia-source
"$DNF" -y remove gcc make ${installed_kernel_devel:+"$installed_kernel_devel"}
"$DNF" clean all
