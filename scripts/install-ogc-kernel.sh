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
  grep -qx 'CONFIG_SCHED_CLASS_EXT=y' /usr/lib/utah/ogc-kernel.config
  grep -Eq '^CONFIG_NTSYNC=(y|m)$' /usr/lib/utah/ogc-kernel.config
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
make defconfig
scripts/config --enable SCHED_CLASS_EXT --enable NTSYNC --enable ANDROID_BINDERFS
scripts/config --set-str LOCALVERSION "-ogc1" --disable LOCALVERSION_AUTO
make olddefconfig
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
test -s /usr/lib/utah/ogc-kernel-release
grep -qx 'CONFIG_SCHED_CLASS_EXT=y' /usr/lib/utah/ogc-kernel.config
grep -Eq '^CONFIG_NTSYNC=(y|m)$' /usr/lib/utah/ogc-kernel.config
