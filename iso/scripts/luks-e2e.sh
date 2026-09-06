#!/usr/bin/env bash
# Install Utah from its live ISO onto an encrypted disk, then boot it.
#
# Four phases, each of which can fail the test on its own:
#   1. boot the live ISO in QEMU with one blank disk attached
#   2. run the installer (fisherman) over SSH with a LUKS passphrase recipe
#   3. boot the installed disk with no ISO, so it must come up on its own
#   4. answer Plymouth's passphrase prompt and confirm the system finishes
#      booting rather than dropping to an emergency shell
#
# Phase 4 is the reason this exists: an image can install perfectly and still
# be unbootable if its initramfs cannot open the root volume.
#
# The live ISO must be a debug build (`just iso testing 1`) because phase 2
# drives the installer over SSH, which only a debug ISO enables.
set -euo pipefail

ISO="${1:?live ISO path is required}"
PAYLOAD_IMAGE="${2:?installed image reference is required}"
PASSPHRASE="${3:-testpassphrase}"
WORK="${UTAH_E2E_WORK:-/var/tmp/utah-luks-e2e}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ISO="$(realpath "${ISO}")"
mkdir -p "${WORK}"
INSTALL_DISK="${WORK}/install.qcow2"
MONITOR_LIVE="${WORK}/live-monitor.sock"
MONITOR_INSTALLED="${WORK}/installed-monitor.sock"
SERIAL_LIVE="${WORK}/live-serial.log"
SERIAL_INSTALLED="${WORK}/installed-serial.log"
SSH_PORT="${UTAH_E2E_SSH_PORT:-2222}"
VARS="${WORK}/ovmf-vars.fd"

QEMU="$(command -v qemu-system-x86_64 /usr/libexec/qemu-kvm 2>/dev/null | head -1)"
[[ -n "${QEMU}" ]] || { echo "qemu-system-x86_64 not found" >&2; exit 1; }

OVMF_CODE=""
for f in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
         /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd \
         /home/linuxbrew/.linuxbrew/share/qemu/edk2-x86_64-code.fd; do
    [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
done
[[ -n "${OVMF_CODE}" ]] || { echo "OVMF firmware not found" >&2; exit 1; }
OVMF_VARS_SRC=""
for f in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd \
         /usr/share/OVMF/OVMF_VARS.fd \
         /home/linuxbrew/.linuxbrew/share/qemu/edk2-i386-vars.fd; do
    [[ -f "$f" ]] && { OVMF_VARS_SRC="$f"; break; }
done
[[ -n "${OVMF_VARS_SRC}" ]] || { echo "OVMF variable store not found" >&2; exit 1; }

ACCEL="-accel kvm"
test -r /dev/kvm || { echo "No /dev/kvm; falling back to TCG (much slower)"; ACCEL="-accel tcg,thread=multi"; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5
          -o PreferredAuthentications=password
          -o ServerAliveInterval=30 -o ServerAliveCountMax=20)
ssh_live() { sshpass -p live ssh "${SSH_OPTS[@]}" -p "${SSH_PORT}" liveuser@127.0.0.1 "$@"; }
scp_live() { sshpass -p live scp "${SSH_OPTS[@]}" -P "${SSH_PORT}" "$@"; }

monitor() {
    python3 - "$1" "$2" <<'PY'
import socket, sys, time
sock, command = sys.argv[1], sys.argv[2]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(10)
    client.connect(sock)
    client.sendall(command.encode() + b"\n")
    time.sleep(0.3)
PY
}

qemu_pids=()
cleanup() {
    for pid in "${qemu_pids[@]:-}"; do
        [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
    done
}
trap cleanup EXIT

echo "=== Phase 1/4: boot the live ISO ==="
rm -f "${INSTALL_DISK}" "${MONITOR_LIVE}" "${MONITOR_INSTALLED}" \
      "${SERIAL_LIVE}" "${SERIAL_INSTALLED}"
qemu-img create -f qcow2 "${INSTALL_DISK}" 64G >/dev/null
cp -f "${OVMF_VARS_SRC}" "${VARS}"

"${QEMU}" \
    -machine q35 -cpu host -m 8192 -smp 4 ${ACCEL} \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${VARS}" \
    -drive "if=none,id=iso,file=${ISO},media=cdrom,readonly=on,format=raw" \
    -device virtio-scsi-pci,id=scsi \
    -device scsi-cd,drive=iso \
    -drive "if=none,id=disk,file=${INSTALL_DISK},format=qcow2" \
    -device virtio-blk-pci,drive=disk \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -monitor "unix:${MONITOR_LIVE},server,nowait" \
    -serial "file:${SERIAL_LIVE}" \
    -display none -daemonize -pidfile "${WORK}/live.pid"
qemu_pids+=("$(cat "${WORK}/live.pid")")

echo "Waiting for the live environment to accept SSH..."
for i in $(seq 1 90); do
    if ssh_live true 2>/dev/null; then echo "Live environment is up."; break; fi
    if [[ "$i" -eq 90 ]]; then
        echo "ERROR: no SSH after 7m30s" >&2
        tail -40 "${SERIAL_LIVE}" >&2 || true
        exit 1
    fi
    sleep 5
done
monitor "${MONITOR_LIVE}" "screendump ${WORK}/screen-live.ppm" || true

echo "=== Phase 2/4: install onto an encrypted disk ==="
cat > "${WORK}/recipe.json" <<EOF
{
  "disk": "/dev/vda",
  "filesystem": "btrfs",
  "image": "",
  "targetImgref": "${PAYLOAD_IMAGE}",
  "composeFsBackend": false,
  "bootloader": "grub2",
  "hostname": "utah-luks-test",
  "encryption": {"type": "luks-passphrase", "passphrase": "${PASSPHRASE}"},
  "flatpaks": []
}
EOF
scp_live "${WORK}/recipe.json" liveuser@127.0.0.1:/tmp/luks-recipe.json

# An empty "image" with a "targetImgref" is the offline shape: fisherman then
# installs from containers-storage rather than pulling, which is the only way
# the ISO's embedded payload gets used. Naming the image directly makes it
# pull, and the image this ISO carries was never published to a registry.
#
# Deliberately no scratch disk mounted at /var/lib/containers. Bluefin's ISO
# pulls the payload from a registry and needs real space for it; Utah's ISO
# carries the image inside the squashfs as a VFS containers-storage graphroot
# at exactly that path, so mounting anything over it hides the payload and the
# install fails with the image "not known".

echo "Running the installer from the ISO's embedded store..."
ssh_live 'sudo /usr/local/bin/fisherman /tmp/luks-recipe.json'
echo "Install reported success. Powering the live VM down..."
monitor "${MONITOR_LIVE}" "system_powerdown" || true
sleep 8
monitor "${MONITOR_LIVE}" "quit" || true
sleep 2

echo "=== Phase 3/4: boot the installed disk ==="
cp -f "${OVMF_VARS_SRC}" "${WORK}/ovmf-vars-installed.fd"
"${QEMU}" \
    -machine q35 -cpu host -m 8192 -smp 4 ${ACCEL} \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${WORK}/ovmf-vars-installed.fd" \
    -drive "if=none,id=disk,file=${INSTALL_DISK},format=qcow2" \
    -device virtio-blk-pci,drive=disk \
    -netdev "user,id=net0,hostfwd=tcp::$((SSH_PORT + 1))-:22" \
    -device virtio-net-pci,netdev=net0 \
    -monitor "unix:${MONITOR_INSTALLED},server,nowait" \
    -serial "file:${SERIAL_INSTALLED}" \
    -display none -daemonize -pidfile "${WORK}/installed.pid"
qemu_pids+=("$(cat "${WORK}/installed.pid")")
sleep 5

echo "=== Phase 4/4: answer the passphrase prompt ==="
status=0
python3 "${ROOT}/iso/scripts/luks-unlock.py" qemu \
    "${MONITOR_INSTALLED}" "${PASSPHRASE}" "${SERIAL_INSTALLED}" || status=$?

if [[ ${status} -eq 0 ]]; then
    echo "PASS: Utah installed to an encrypted disk, unlocked, and booted."
else
    echo "FAIL: LUKS unlock or post-unlock boot failed (exit ${status})." >&2
    tail -60 "${SERIAL_INSTALLED}" >&2 || true
fi
exit "${status}"
