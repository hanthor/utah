#!/usr/bin/env bash
# Put the OGC kernel used by Dakota's gaming images into this image.  Hummingbird
# publishes no OGC RPM, so this is intentionally a source build rather than a
# silently substituted Fedora kernel.
#
# Compiling it takes about half an hour, and it depends on nothing this image
# does -- only on the base image and the pin below.  Rebuilding it on every push
# was pure waste, so the compile is hoisted into a cache image built from
# Containerfile.kernel and keyed by those two inputs; see `just kernel-cache-tag`.
# When that image is the base, the kernel arrives as a tarball and this script
# unpacks it.  With no cache present -- a local `just build`, or the cache image's
# own build -- it falls through to the source build, so both paths stay exercised
# and neither can rot unnoticed.
set -euo pipefail

CACHE_DIR="${UTAH_KERNEL_CACHE_DIR:-/utah-cache}"
DNF="$(command -v dnf5 || command -v dnf)"

if [ -f "${CACHE_DIR}/ogc.tar" ]; then
  echo "Unpacking the prebuilt OGC kernel from ${CACHE_DIR}/ogc.tar"
  tar -C / -xf "${CACHE_DIR}/ogc.tar"
  release="$(cat /usr/lib/utah/ogc-kernel-release)"
  # modules.dep and friends are in the tarball, but the base kernel this image
  # carries may differ from the one the cache was built on.  Regenerating is
  # cheap and makes the outcome independent of that.
  depmod -a "$release"
  ln -sfn "vmlinuz-${release}" /boot/vmlinuz
  test -s /usr/lib/utah/ogc-kernel-release
  for want in '^CONFIG_SCHED_CLASS_EXT=y$' '^CONFIG_NTSYNC=(y|m)$' '^CONFIG_ANDROID_BINDERFS=y$'; do
    grep -Eq "$want" /usr/lib/utah/ogc-kernel.config || {
      echo "cached OGC config does not satisfy $want" >&2; exit 1; }
  done
  exit 0
fi

# The pin was written as a `git describe --long` string --
#   v7.1.8-ogc1-0-g86a4e13f16fb876282a12cc7680b3eb73d990e6b
# -- and handed to `git clone --branch`, which takes a ref, not a description.
# No such ref exists, so every gaming build died on
#   fatal: Remote branch v7.1.8-ogc1-0-g86a4... not found in upstream origin
# The tag is the part before the -0-g suffix, and the suffix is the commit it
# pointed at. Both are kept: the tag is what git can clone, and the commit is
# checked afterwards so a moved tag is caught rather than silently built.
OGC_TAG="${OGC_KERNEL_TAG:-v7.1.8-ogc1}"
OGC_COMMIT="${OGC_KERNEL_COMMIT:-86a4e13f16fb876282a12cc7680b3eb73d990e6b}"
builddir=/usr/src/utah-ogc

toolchain=(bc bison cpio elfutils-libelf-devel flex gcc git make openssl-devel
           pahole perl python3 rsync xz zstd)
# Which of those the image did not already have.  The unconditional `dnf remove`
# this used to end with would happily take out git, python3 or perl when they
# were part of the package contract rather than something we pulled in.
absent=()
for pkg in "${toolchain[@]}"; do
  rpm -q "$pkg" >/dev/null 2>&1 || absent+=("$pkg")
done

"$DNF" -y install "${toolchain[@]}"
git clone --depth 1 --branch "$OGC_TAG" https://github.com/OpenGamingCollective/linux.git "$builddir"
pushd "$builddir"
# A tag is mutable. Refuse to build anything other than the commit we pinned.
actual_commit="$(git rev-parse HEAD)"
if [ "$actual_commit" != "$OGC_COMMIT" ]; then
  echo "OGC tag $OGC_TAG resolves to $actual_commit, expected $OGC_COMMIT" >&2
  exit 1
fi
# A shallow clone does not fetch the tag object, so scripts/setlocalversion
# decides the tree is not at a release and appends "+" -- the kernel came out as
# 7.1.8-ogc1+, which reads as a modified tree. It is not modified: the commit is
# checked against the pin immediately above. An empty .scmversion suppresses the
# suffix without pretending the tree is something it is not.
: > .scmversion

make defconfig
# Each of these three needs its dependencies enabled too, or olddefconfig drops
# it again without a word:
#
#   SCHED_CLASS_EXT depends on BPF_SYSCALL && BPF_JIT && DEBUG_INFO_BTF
#   DEBUG_INFO_BTF  depends on BPF_SYSCALL, !DEBUG_INFO_REDUCED, pahole >= 1.22,
#                   and on DEBUG_INFO, which is not settable directly -- it is
#                   selected by picking a DWARF format out of a choice whose
#                   default is DEBUG_INFO_NONE
#   ANDROID_BINDERFS depends on ANDROID_BINDER_IPC, which is default n
#
# x86_64 defconfig has none of them, so asking only for the three features got
# all three silently discarded: no sched_ext for the gaming scheduler, and no
# binderfs. Enabling DEBUG_INFO makes the build slower and the tree much larger,
# which is the price of BTF; the kernel that ships is unaffected, since only
# bzImage is installed and modules go through INSTALL_MOD_STRIP=1.
scripts/config --enable BPF_SYSCALL --enable BPF_JIT \
               --disable DEBUG_INFO_NONE \
               --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
               --enable DEBUG_INFO_BTF \
               --enable SCHED_CLASS_EXT \
               --enable ANDROID_BINDER_IPC --enable ANDROID_BINDERFS \
               --enable NTSYNC
scripts/config --set-str LOCALVERSION "-ogc1" --disable LOCALVERSION_AUTO
make olddefconfig

# Check the config the moment it is settled, not after the compile. The build
# below takes about half an hour, and these options are the only reason this
# kernel exists rather than Fedora's -- discovering afterwards that one of them
# is missing wastes the whole run. `scripts/config --enable` writes the line
# whether or not the option is reachable; olddefconfig is what decides.
require_config() {
  if ! grep -Eq "$1" .config; then
    echo "OGC kernel: olddefconfig dropped $2. Related settings:" >&2
    grep -E "^# ?CONFIG_(SCHED_CLASS_EXT|NTSYNC|ANDROID_BINDER|DEBUG_INFO|BPF_SYSCALL|BPF_JIT)" .config >&2 || true
    grep -E "^CONFIG_(SCHED_CLASS_EXT|NTSYNC|ANDROID_BINDER|DEBUG_INFO|BPF_SYSCALL|BPF_JIT)" .config >&2 || true
    exit 1
  fi
}
require_config '^CONFIG_SCHED_CLASS_EXT=y$' CONFIG_SCHED_CLASS_EXT
require_config '^CONFIG_NTSYNC=(y|m)$' CONFIG_NTSYNC
require_config '^CONFIG_ANDROID_BINDERFS=y$' CONFIG_ANDROID_BINDERFS

make modules_prepare
make -j"$(nproc)" bzImage modules
release="$(make -s kernelrelease)"
make modules_install INSTALL_MOD_PATH=/usr INSTALL_MOD_STRIP=1
install -Dm0644 arch/x86/boot/bzImage "/boot/vmlinuz-${release}"
ln -sfn "vmlinuz-${release}" /boot/vmlinuz
install -Dm0644 .config "/usr/lib/modules/${release}/config"
# Preserve the minimal external-module build tree.  NVIDIA's open module is
# compiled against this exact tree for the nvidia-gaming flavor.
kernel_build="/usr/src/linux-${release}"
install -d "$kernel_build"
cp -a Makefile Module.symvers .config arch/x86 include scripts "$kernel_build/"
ln -sfn "$kernel_build" "/usr/lib/modules/${release}/build"
depmod -a "$release"
install -Dm0644 .config /usr/lib/utah/ogc-kernel.config
printf '%s\n' "$release" >/usr/lib/utah/ogc-kernel-release
popd
rm -rf "$builddir"

# Everything the cache image needs to hand a later build, in one archive so no
# caller has to know the release string or which paths a kernel install touches.
if [ -n "${UTAH_KERNEL_CACHE_OUT:-}" ]; then
  tar -C / -cf "${UTAH_KERNEL_CACHE_OUT}" \
    "boot/vmlinuz-${release}" \
    "usr/lib/modules/${release}" \
    "usr/src/linux-${release}" \
    usr/lib/utah/ogc-kernel.config \
    usr/lib/utah/ogc-kernel-release
fi

if [ "${#absent[@]}" -gt 0 ]; then
  "$DNF" -y remove "${absent[@]}"
fi
"$DNF" clean all
# The same three, re-checked against what was actually installed. These cannot
# fail once the pre-build check passes, which is the point: a failure here would
# mean the config that shipped is not the config that was built.
test -s /usr/lib/utah/ogc-kernel-release
for want in '^CONFIG_SCHED_CLASS_EXT=y$' '^CONFIG_NTSYNC=(y|m)$' '^CONFIG_ANDROID_BINDERFS=y$'; do
  grep -Eq "$want" /usr/lib/utah/ogc-kernel.config || {
    echo "installed OGC config does not satisfy $want" >&2; exit 1; }
done
