#!/usr/bin/env bash
set -euo pipefail

IMAGE_REF="${1:-}"
if [[ -z "${IMAGE_REF}" ]]; then
    echo "Usage: $0 <image-ref>"
    exit 1
fi

SSH_PORT="${SSH_PORT:-2222}"
DISK_SIZE="${DISK_SIZE:-32G}"
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-360}"
QCOW_PATH="output/qcow2/disk.qcow2"
RAW_PATH="output/raw/disk.raw"
SOURCE_OCI_DIR="output/source-oci"
ARTIFACT_DIR="${CI_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/omarchy-bootc-artifacts}"
QEMU_PIDFILE="${RUNNER_TEMP:-/tmp}/omarchy-bootc-qemu.pid"
QEMU_LOG="${RUNNER_TEMP:-/tmp}/omarchy-bootc-qemu.log"
QEMU_OVMF_VARS="${RUNNER_TEMP:-/tmp}/omarchy-bootc-ovmf-vars.fd"
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=3
    -o LogLevel=ERROR
    -p "${SSH_PORT}"
)
OVMF_CODE_PATH=""
OVMF_VARS_TEMPLATE=""

find_first_existing_file() {
    local candidate=""

    for candidate in "$@"; do
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

rootful_copy_image() {
    local image_ref="${1}"
    local rootless_id=""
    local rootful_id=""
    local copy_tmp=""

    if [[ "$(id -u)" == 0 ]]; then
        echo "Already running as uid 0; rootful image handoff is unnecessary."
        return
    fi

    if ! command -v machinectl >/dev/null 2>&1; then
        echo "machinectl is required for podman image scp when copying into rootful podman"
        exit 1
    fi

    rootless_id="$(podman images --filter "reference=${image_ref}" --format '{{.ID}}' | head -n 1)"
    if [[ -z "${rootless_id}" ]]; then
        echo "Unable to locate rootless image for ${image_ref}"
        exit 1
    fi

    rootful_id="$(sudo podman images --filter "reference=${image_ref}" --format '{{.ID}}' | head -n 1 || true)"
    if [[ "${rootful_id}" == "${rootless_id}" ]]; then
        return
    fi

    copy_tmp="$(mktemp -d -p "${PWD}" -t _build_podman_scp.XXXXXXXXXX)"
    sudo TMPDIR="${copy_tmp}" podman image scp \
        "$(id -u)@localhost::${image_ref}" \
        "root@localhost::${image_ref}"
    rm -rf "${copy_tmp}"
}

if ! command -v qemu-img >/dev/null 2>&1; then
    echo "qemu-img is required for bootc install-to-disk smoke tests."
    exit 1
fi

mkdir -p "${ARTIFACT_DIR}"

OVMF_CODE_PATH="$(find_first_existing_file \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    || true)"
OVMF_VARS_TEMPLATE="$(find_first_existing_file \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd \
    /usr/share/edk2/ovmf/OVMF_VARS.fd \
    || true)"

if [[ -z "${OVMF_CODE_PATH}" || -z "${OVMF_VARS_TEMPLATE}" ]]; then
    echo "Unable to locate OVMF UEFI firmware. Install the ovmf package (or equivalent) before running the VM smoke test."
    exit 1
fi

cp "${OVMF_VARS_TEMPLATE}" "${QEMU_OVMF_VARS}"
{
    echo "OVMF_CODE_PATH=${OVMF_CODE_PATH}"
    echo "OVMF_VARS_TEMPLATE=${OVMF_VARS_TEMPLATE}"
    echo "QEMU_OVMF_VARS=${QEMU_OVMF_VARS}"
} >"${ARTIFACT_DIR}/qemu-firmware.txt"

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
    write_artifact guest-sddm-status.txt run_guest 'systemctl status sddm --no-pager --full'
    write_artifact guest-sshd-status.txt run_guest 'systemctl status sshd --no-pager --full'
    write_artifact guest-journal.txt run_guest 'journalctl -b --no-pager'
    run_guest 'sudo -n bootc status --format=json' \
        >"${ARTIFACT_DIR}/guest-bootc-status.json" 2>"${ARTIFACT_DIR}/guest-bootc-status.stderr" || true
    run_guest 'test ! -d "$HOME/acceptance-receipts" || tar -C "$HOME" -czf - acceptance-receipts' \
        >"${ARTIFACT_DIR}/guest-acceptance-receipts.tar.gz" 2>"${ARTIFACT_DIR}/guest-acceptance-receipts.stderr" || true
    write_artifact guest-firstboot.txt run_guest 'systemctl status omarchy-acceptance-firstboot --no-pager --full; ls -l /var/lib/omarchy-acceptance /home/omarchy/.local/state/omarchy/done'
    write_artifact guest-home-config.txt run_guest 'find /home/omarchy/.config -maxdepth 2 -mindepth 1 -type d | sort'
}

capture_host_diagnostics() {
    if [[ -f "${QEMU_LOG}" ]]; then
        cp "${QEMU_LOG}" "${ARTIFACT_DIR}/qemu-serial.log"
    fi

    if [[ -f "${QEMU_PIDFILE}" ]]; then
        cp "${QEMU_PIDFILE}" "${ARTIFACT_DIR}/qemu.pid"
    fi

    if [[ -f "${RAW_PATH}" ]] && command -v qemu-img >/dev/null 2>&1; then
        write_artifact raw-info.txt qemu-img info "${RAW_PATH}"
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
    capture_guest_diagnostics
    if [[ -f "${QEMU_PIDFILE}" ]]; then
        kill "$(cat "${QEMU_PIDFILE}")" >/dev/null 2>&1 || true
        rm -f "${QEMU_PIDFILE}"
    fi
    rm -f "${QEMU_OVMF_VARS}"
}
trap cleanup EXIT

mkdir -p output
rm -rf output/qcow2 output/raw "${SOURCE_OCI_DIR}"

echo "::group::Preflight bootc image state"
IMAGE_ID="$(podman inspect image "${IMAGE_REF}" --format '{{.Id}}')"
echo "Resolved image ref: ${IMAGE_REF}" | tee "${ARTIFACT_DIR}/image-ref.txt"
echo "Resolved image ID: ${IMAGE_ID}" | tee "${ARTIFACT_DIR}/image-id.txt"

podman run --rm --pull=never "${IMAGE_REF}" bash -lc '
set -euo pipefail
echo "bootc=$(bootc --version | head -n1)"
bootc container lint --fatal-warnings
find /usr/lib/modules -mindepth 1 -maxdepth 2 \( -name initramfs.img -o -name vmlinuz \) | sort
' 2>&1 | tee "${ARTIFACT_DIR}/image-preflight.log"
echo "::endgroup::"

echo "::group::Prepare rootful image for bootc install"
rootful_copy_image "${IMAGE_REF}" \
    2>&1 | tee "${ARTIFACT_DIR}/rootful-image-copy.log"
echo "::endgroup::"

echo "::group::Export explicit install source image"
podman save --format oci-dir --output "${SOURCE_OCI_DIR}" "${IMAGE_REF}" \
    2>&1 | tee "${ARTIFACT_DIR}/source-oci-export.log"
cp "${SOURCE_OCI_DIR}/index.json" "${ARTIFACT_DIR}/acceptance-oci-index.json"
expected_digest="$(jq -er '.manifests[0].digest' "${SOURCE_OCI_DIR}/index.json")"
SOURCE_IMGREF="oci:/data/${SOURCE_OCI_DIR}"
echo "Using source imgref: ${SOURCE_IMGREF}" | tee "${ARTIFACT_DIR}/source-imgref.txt"
echo "::endgroup::"

echo "::group::Generate qcow2 via bootc install-to-disk"
mkdir -p "$(dirname "${RAW_PATH}")" "$(dirname "${QCOW_PATH}")"
truncate -s "${DISK_SIZE}" "${RAW_PATH}"
echo "Sparse disk size: ${DISK_SIZE}" | tee "${ARTIFACT_DIR}/disk-size.txt"

sudo podman run --rm --privileged --pid=host --pull=never \
    -v /dev:/dev \
    -v /var/lib/containers:/var/lib/containers \
    -v /etc/containers:/etc/containers \
    -v "${PWD}:/data" \
    "${IMAGE_REF}" \
    bootc install to-disk --source-imgref "${SOURCE_IMGREF}" --composefs-backend --via-loopback "/data/${RAW_PATH}" --filesystem btrfs --wipe --bootloader systemd \
    2>&1 | tee "${ARTIFACT_DIR}/bootc-install.log"

qemu-img convert -O qcow2 "${RAW_PATH}" "${QCOW_PATH}"
echo "::endgroup::"

if [[ ! -f "${QCOW_PATH}" ]]; then
    fail "Expected qcow2 image not found at ${QCOW_PATH}"
fi

echo "::group::Boot qcow2 in headless QEMU"
QEMU_ACCEL="tcg"
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU_ACCEL="kvm"
    echo "KVM is available and accessible." | tee "${ARTIFACT_DIR}/kvm-capability.txt"
elif [[ -e /dev/kvm ]]; then
    echo "KVM device exists but is not accessible; falling back to software emulation." \
        | tee -a "${ARTIFACT_DIR}/qemu-accel.txt"
    echo "KVM exists but is inaccessible." | tee "${ARTIFACT_DIR}/kvm-capability.txt"
else
    echo "KVM device is absent; using software emulation." | tee "${ARTIFACT_DIR}/kvm-capability.txt"
fi
echo "Using QEMU accelerator: ${QEMU_ACCEL}" | tee -a "${ARTIFACT_DIR}/qemu-accel.txt"

qemu-system-x86_64 \
    -name omarchy-bootc-smoke \
    -machine q35,accel="${QEMU_ACCEL}" \
    -cpu max \
    -smp 2 \
    -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE_PATH}" \
    -drive if=pflash,format=raw,file="${QEMU_OVMF_VARS}" \
    -display none \
    -serial file:"${QEMU_LOG}" \
    -monitor none \
    -drive if=virtio,format=qcow2,file="${QCOW_PATH}" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
    -device virtio-net-pci,netdev=net0 \
    -daemonize \
    -pidfile "${QEMU_PIDFILE}"
echo "::endgroup::"

echo "::group::Wait for SSH availability"
for _ in $(seq 1 "$((SSH_WAIT_SECONDS / 2))"); do
    if run_guest 'echo ssh-up' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! run_guest 'echo ssh-up' >/dev/null 2>&1; then
    fail "SSH did not become available in time."
fi
echo "::endgroup::"

echo "::group::Wait for acceptance provisioning"
for _ in $(seq 1 "$((SSH_WAIT_SECONDS / 2))"); do
    if run_guest 'test -f /var/lib/omarchy-acceptance/ready && test -f /home/omarchy/.local/state/omarchy/done/finalize-user'; then
        break
    fi
    sleep 2
done

if ! run_guest 'test -f /var/lib/omarchy-acceptance/ready && test -f /home/omarchy/.local/state/omarchy/done/finalize-user'; then
    fail "Acceptance first-boot provisioning did not complete in time."
fi
echo "::endgroup::"

echo "::group::Run in-VM smoke checks"
run_guest 'set -euo pipefail
id omarchy
[[ -f /var/lib/omarchy-acceptance/ready ]]
[[ -f /home/omarchy/.local/state/omarchy/done/finalize-user ]]
systemctl is-active sddm
systemctl is-active sshd
[[ -d /home/omarchy/.config/hypr ]]
[[ -f /usr/share/sddm/themes/omarchy/Main.qml ]]
[[ -f /usr/share/omarchy/default/wayland-sessions/omarchy.desktop ]]
[[ -f /usr/share/wayland-sessions/omarchy.desktop ]]
cmp --silent /usr/share/omarchy/default/wayland-sessions/omarchy.desktop /usr/share/wayland-sessions/omarchy.desktop
[[ "$(pacman -Qoq /usr/bin/omarchy)" == omarchy ]]
[[ "$(pacman -Qoq /usr/bin/omarchy-menu)" == omarchy ]]
[[ "$(pacman -Qoq /usr/bin/omarchy-theme-list)" == omarchy ]]
[[ -d /usr/share/omarchy/shell ]]
[[ -d /usr/share/omarchy/themes ]]' || fail "In-VM runtime checks failed."
echo "::endgroup::"

run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/first-boot-status.json"
jq -e 'type == "object"' "${ARTIFACT_DIR}/first-boot-status.json" >/dev/null
jq -e --arg digest "${expected_digest}" '.status.booted.image.imageDigest == $digest' \
    "${ARTIFACT_DIR}/first-boot-status.json" >/dev/null \
    || fail "Booted acceptance digest differs from the installed OCI manifest."

acceptance_status=0
if [[ -n "${UPSTREAM_ACCEPTANCE_DIR:-}" ]]; then
    # scp uses -P rather than ssh's -p. Transfer only tests, never the source .git.
    sshpass -p omarchy scp -r -P "${SSH_PORT}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${UPSTREAM_ACCEPTANCE_DIR}/test" omarchy@127.0.0.1:upstream-acceptance-test
    run_guest 'mkdir -p "$HOME/upstream-acceptance/test"; cp -a "$HOME/upstream-acceptance-test/." "$HOME/upstream-acceptance/test/"'
    if ! run_guest 'env OMARCHY_ACCEPTANCE_DIR="$HOME/acceptance-receipts/upstream" OMARCHY_ACCEPTANCE_TEST_TIMEOUT=120 timeout 20m bash "$HOME/upstream-acceptance/test/acceptance"' \
        2>&1 | tee "${ARTIFACT_DIR}/upstream-acceptance.log"; then
        acceptance_status=1
    fi
fi

if [[ -n "${NATIVE_ACCEPTANCE_SCRIPT:-}" ]]; then
    sshpass -p omarchy scp -P "${SSH_PORT}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${NATIVE_ACCEPTANCE_SCRIPT}" omarchy@127.0.0.1:guest-native-acceptance.sh
    if run_guest 'env OMARCHY_ACCEPTANCE_DIR="$HOME/acceptance-receipts/native" timeout 5m bash "$HOME/guest-native-acceptance.sh" prepare' \
        2>&1 | tee "${ARTIFACT_DIR}/native-prepare.log"; then
        before_boot="$(run_guest 'cat /proc/sys/kernel/random/boot_id')"
        printf '%s\n' "${before_boot}" >"${ARTIFACT_DIR}/before-reboot-id.txt"
        run_guest 'sudo -n systemctl reboot' || true
        rebooted=false
        for _ in $(seq 1 180); do
            sleep 2
            after_boot="$(run_guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
            if [[ -n "${after_boot}" && "${after_boot}" != "${before_boot}" ]]; then
                printf '%s\n' "${after_boot}" >"${ARTIFACT_DIR}/after-reboot-id.txt"
                rebooted=true
                break
            fi
        done
        if [[ "${rebooted}" != true ]]; then
            fail "A changed kernel boot ID was not observed after reboot."
        fi
        run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/after-reboot-status.json"
        jq -e --arg digest "${expected_digest}" '.status.booted.image.imageDigest == $digest' \
            "${ARTIFACT_DIR}/after-reboot-status.json" >/dev/null \
            || fail "Acceptance digest changed during the persistence reboot."
        if ! run_guest 'env OMARCHY_ACCEPTANCE_DIR="$HOME/acceptance-receipts/native" timeout 5m bash "$HOME/guest-native-acceptance.sh" verify' \
            2>&1 | tee "${ARTIFACT_DIR}/native-after-reboot.log"; then
            acceptance_status=1
        fi
    else
        acceptance_status=1
    fi
fi

capture_host_diagnostics
capture_guest_diagnostics
((acceptance_status == 0)) || fail "One or more graphical/native acceptance checks failed; inspect individual receipts."
echo "Requested first-boot/runtime checks passed. A/B rollback and Dakota round-trip still require separate evidence."
