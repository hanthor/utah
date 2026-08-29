#!/usr/bin/env bash
# Prefer a Hummingbird RPM when it exists.  Its published repository does not
# presently carry one, so use UBlue's Alma/CoreOS-style akmods payload.  The
# payload includes the kernel RPMs and kmods built together; we refuse to mix
# it with any unrelated kernel.
set -euo pipefail

flavor="$1"
DNF="$(command -v dnf5 || command -v dnf)"
fedora="$(rpm -E '%{fedora}')"

# The user-space RPMs come from the same UBlue bundle for both flavors.  For
# nvidia-gaming the bundle's *prebuilt* kmod is removed and rebuilt from
# NVIDIA's matching open source against the OGC tree below.
kernel="$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -n1)"
tag="${UTAH_AKMODS_FLAVOR:-coreos-stable}-${fedora}-${kernel}"

workdir=/tmp/utah-akmods
mkdir -p "$workdir"
"$DNF" -y install skopeo tar
skopeo copy --retry-times 3 "docker://ghcr.io/ublue-os/akmods-nvidia-open:${tag}" "dir:${workdir}"
layer="$(python3 - "$workdir/manifest.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['layers'][0]['digest'].split(':', 1)[1])
PY
)"
tar -xzf "$workdir/$layer" -C /tmp
test -x /tmp/rpms/ublue-os/nvidia-install.sh
rpm --import https://download.copr.fedorainfracloud.org/results/ublue-os/staging/pubkey.gpg
IMAGE_NAME=utah AKMODNV_PATH=/tmp/rpms MULTILIB=0 /tmp/rpms/ublue-os/nvidia-install.sh
install -d /usr/lib/bootc/kargs.d /usr/lib/modprobe.d
printf '%s\n' 'blacklist nouveau' 'options nouveau modeset=0' >/usr/lib/modprobe.d/00-nouveau-blacklist.conf
printf '%s\n' 'kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]' >/usr/lib/bootc/kargs.d/00-nvidia.toml

if [[ "$flavor" == nvidia-gaming ]]; then
  ogc_release="$(cat /usr/lib/utah/ogc-kernel-release)"
  driver_version="$(rpm -q nvidia-driver --qf '%{VERSION}')"
  "$DNF" -y install make gcc
  curl --retry 3 -fsSLo /tmp/nvidia.run "https://us.download.nvidia.com/XFree86/Linux-x86_64/${driver_version}/NVIDIA-Linux-x86_64-${driver_version}.run"
  sh /tmp/nvidia.run --extract-only --target /tmp/nvidia-source
  make -C "/usr/lib/modules/${ogc_release}/build" M=/tmp/nvidia-source/kernel-open modules
  install -d "/usr/lib/modules/${ogc_release}/extra/nvidia"
  find /tmp/nvidia-source/kernel-open -name 'nvidia*.ko' -exec install -m0644 -t "/usr/lib/modules/${ogc_release}/extra/nvidia" {} +
  depmod -a "$ogc_release"
  rm -rf /tmp/nvidia.run /tmp/nvidia-source
  "$DNF" -y remove kmod-nvidia make gcc || true
  test -n "$(find "/usr/lib/modules/${ogc_release}/extra/nvidia" -name 'nvidia.ko' -print -quit)"
else
  rpm -qi kmod-nvidia
fi
rpm -qi nvidia-driver nvidia-driver-cuda nvidia-container-toolkit
