#!/usr/bin/env bash
set -euo pipefail

IMAGE_REF="${1:-}"
if [[ -z "${IMAGE_REF}" ]]; then
    echo "Usage: $0 <image-ref>"
    exit 1
fi

BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
SSH_PORT="${SSH_PORT:-2222}"
QCOW_PATH="output/qcow2/disk.qcow2"
ARTIFACT_DIR="${CI_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/omarchy-bootc-artifacts}"
QEMU_PIDFILE="${RUNNER_TEMP:-/tmp}/omarchy-bootc-qemu.pid"
QEMU_LOG="${RUNNER_TEMP:-/tmp}/omarchy-bootc-qemu.log"
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=3
    -p "${SSH_PORT}"
)

mkdir -p "${ARTIFACT_DIR}"

run_guest() {
    sshpass -p omarchy ssh "${SSH_OPTS[@]}" omarchy@127.0.0.1 "$@"
}

write_artifact() {
    local name="${1}"
    shift

    "$@" >"${ARTIFACT_DIR}/${name}" 2>&1 || true
}

capture_guest_diagnostics() {
    if ! run_guest 'echo guest-up' >/dev/null 2>&1; then
        return
    fi

    write_artifact guest-uname.txt run_guest 'uname -a'
    write_artifact guest-id.txt run_guest 'id'
    write_artifact guest-systemd-failed.txt run_guest 'systemctl --failed --no-pager --full'
    write_artifact guest-greetd-status.txt run_guest 'systemctl status greetd --no-pager --full'
    write_artifact guest-sshd-status.txt run_guest 'systemctl status sshd --no-pager --full'
    write_artifact guest-journal.txt run_guest 'journalctl -b --no-pager'
    write_artifact guest-firstboot.txt run_guest 'ls -l /var/lib/omarchy /var/lib/omarchy/.firstboot-done'
    write_artifact guest-home-config.txt run_guest 'find /home/omarchy/.config -maxdepth 2 -mindepth 1 -type d | sort'
}

capture_host_diagnostics() {
    if [[ -f "${QEMU_LOG}" ]]; then
        cp "${QEMU_LOG}" "${ARTIFACT_DIR}/qemu-serial.log"
    fi

    if [[ -f "${QEMU_PIDFILE}" ]]; then
        cp "${QEMU_PIDFILE}" "${ARTIFACT_DIR}/qemu.pid"
    fi

    if [[ -f "${QCOW_PATH}" ]] && command -v qemu-img >/dev/null 2>&1; then
        write_artifact qcow-info.txt qemu-img info "${QCOW_PATH}"
    fi

    write_artifact host-date.txt date -u
    write_artifact host-kernel.txt uname -a
}

fail() {
    local message="${1}"

    capture_host_diagnostics
    capture_guest_diagnostics

    echo "${message}"
    if [[ -f "${QEMU_LOG}" ]]; then
        echo "QEMU serial log (tail):"
        tail -n 200 "${QEMU_LOG}" || true
    fi
    echo "Diagnostics written to ${ARTIFACT_DIR}"
    exit 1
}

cleanup() {
    capture_host_diagnostics
    if [[ -f "${QEMU_PIDFILE}" ]]; then
        kill "$(cat "${QEMU_PIDFILE}")" >/dev/null 2>&1 || true
        rm -f "${QEMU_PIDFILE}"
    fi
}
trap cleanup EXIT

mkdir -p output
rm -rf output/qcow2

echo "::group::Preflight boot artifact compatibility inside image"
podman run --rm "${IMAGE_REF}" bash -lc '
set -euo pipefail
kver=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort -V | tail -n1)
echo "kver=${kver}"
ls -l /boot/initramfs-*
ls -l /usr/lib/modules/*/initramfs.img
lsinitrd -k "${kver}"
' 2>&1 | tee "${ARTIFACT_DIR}/image-preflight.log"
echo "::endgroup::"

echo "::group::Prepare rootful image for bootc-image-builder"
podman image save "${IMAGE_REF}" -o output/image.tar \
    2>&1 | tee "${ARTIFACT_DIR}/podman-image-save.log"
sudo podman image load -i output/image.tar \
    2>&1 | tee "${ARTIFACT_DIR}/podman-image-load.log"
rm -f output/image.tar
echo "::endgroup::"

echo "::group::Generate qcow2 from container image"
sudo podman run --rm --privileged --pull=newer --net=host \
    -v "${PWD}/image/disk.toml:/config.toml:ro" \
    -v "${PWD}/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${BIB_IMAGE}" \
    --type qcow2 \
    --rootfs btrfs \
    "${IMAGE_REF}" \
    2>&1 | tee "${ARTIFACT_DIR}/bootc-image-builder.log"
echo "::endgroup::"

if [[ ! -f "${QCOW_PATH}" ]]; then
    fail "Expected qcow2 image not found at ${QCOW_PATH}"
fi

echo "::group::Boot qcow2 in headless QEMU"
QEMU_ACCEL="tcg"
if [[ -e /dev/kvm ]]; then
    QEMU_ACCEL="kvm"
fi

qemu-system-x86_64 \
    -name omarchy-bootc-smoke \
    -machine q35,accel="${QEMU_ACCEL}" \
    -cpu max \
    -smp 2 \
    -m 4096 \
    -nographic \
    -serial file:"${QEMU_LOG}" \
    -monitor none \
    -drive if=virtio,format=qcow2,file="${QCOW_PATH}" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
    -device virtio-net-pci,netdev=net0 \
    -daemonize \
    -pidfile "${QEMU_PIDFILE}"
echo "::endgroup::"

echo "::group::Wait for SSH availability"
for _ in $(seq 1 180); do
    if run_guest 'echo ssh-up' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! run_guest 'echo ssh-up' >/dev/null 2>&1; then
    fail "SSH did not become available in time."
fi
echo "::endgroup::"

echo "::group::Run in-VM smoke checks"
run_guest 'set -euo pipefail
id omarchy
[[ -f /var/lib/omarchy/.firstboot-done ]]
systemctl is-active greetd
systemctl is-active sshd
[[ -d /home/omarchy/.config/hypr ]]
[[ -d /home/omarchy/.config/waybar ]]
[[ -d /home/omarchy/.config/wofi ]]
[[ -d /home/omarchy/.config/mako ]]' || fail "In-VM smoke checks failed."
echo "::endgroup::"

capture_host_diagnostics
capture_guest_diagnostics
echo "VM smoke test passed."
