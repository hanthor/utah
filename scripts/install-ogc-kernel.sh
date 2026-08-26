#!/usr/bin/env bash
# Build the OGC kernel used by Dakota's gaming images.  Hummingbird currently
# publishes no OGC RPM, so this is intentionally a source build rather than a
# silently substituted Fedora kernel.
set -euo pipefail

DNF="$(command -v dnf5 || command -v dnf)"
OGC_REF="${OGC_KERNEL_REF:-v7.1.8-ogc1-0-g86a4e13f16fb876282a12cc7680b3eb73d990e6b}"
builddir=/usr/src/utah-ogc

"$DNF" -y install \
  bc bison cpio elfutils-libelf-devel flex gcc git make openssl-devel pahole \
  perl python3 rsync xz zstd
git clone --depth 1 --branch "$OGC_REF" https://github.com/OpenGamingCollective/linux.git "$builddir"
pushd "$builddir"
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
"$DNF" -y remove bc bison cpio elfutils-libelf-devel flex gcc git make openssl-devel pahole perl python3 rsync xz zstd
"$DNF" clean all
test -s /usr/lib/utah/ogc-kernel-release
grep -qx 'CONFIG_SCHED_CLASS_EXT=y' /usr/lib/utah/ogc-kernel.config
grep -Eq '^CONFIG_NTSYNC=(y|m)$' /usr/lib/utah/ogc-kernel.config
