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
QEMU_PIDFILE="${RUNNER_TEMP:-/tmp}/omarchy-bootc-qemu.pid"
QEMU_LOG="${RUNNER_TEMP:-/tmp}/omarchy-bootc-qemu.log"

cleanup() {
    if [[ -f "${QEMU_PIDFILE}" ]]; then
        kill "$(cat "${QEMU_PIDFILE}")" >/dev/null 2>&1 || true
        rm -f "${QEMU_PIDFILE}"
    fi
}
trap cleanup EXIT

mkdir -p output
rm -rf output/qcow2

echo "::group::Prepare rootful image for bootc-image-builder"
podman image save "${IMAGE_REF}" -o output/image.tar
sudo podman image load -i output/image.tar
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
    "${IMAGE_REF}"
echo "::endgroup::"

if [[ ! -f "${QCOW_PATH}" ]]; then
    echo "Expected qcow2 image not found at ${QCOW_PATH}"
    exit 1
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
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -daemonize \
    -pidfile "${QEMU_PIDFILE}"
echo "::endgroup::"

echo "::group::Wait for SSH availability"
for _ in $(seq 1 180); do
    if sshpass -p omarchy ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p "${SSH_PORT}" omarchy@127.0.0.1 'echo ssh-up' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! sshpass -p omarchy ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p "${SSH_PORT}" omarchy@127.0.0.1 'echo ssh-up' >/dev/null 2>&1; then
    echo "SSH did not become available in time."
    echo "QEMU serial log (tail):"
    tail -n 200 "${QEMU_LOG}" || true
    exit 1
fi
echo "::endgroup::"

echo "::group::Run in-VM smoke checks"
sshpass -p omarchy ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "${SSH_PORT}" omarchy@127.0.0.1 'set -euo pipefail
id omarchy
[[ -f /var/lib/omarchy/.firstboot-done ]]
systemctl is-active greetd
systemctl is-active sshd
[[ -d /home/omarchy/.config/hypr ]]
[[ -d /home/omarchy/.config/waybar ]]
[[ -d /home/omarchy/.config/wofi ]]
[[ -d /home/omarchy/.config/mako ]]'
echo "::endgroup::"

echo "VM smoke test passed."
