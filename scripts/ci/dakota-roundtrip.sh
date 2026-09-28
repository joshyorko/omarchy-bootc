#!/usr/bin/env bash
set -euo pipefail

# Gate 4: boot a current, immutable Dakota input, switch to the accepted
# Quattro artifact, then switch back to the same Dakota release. This is a
# hosted test only. It records live bootc status from each guest; source
# repository metadata is never used as a substitute for that evidence.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/ci/lib/dakota-receipt.sh
source "${ROOT_DIR}/scripts/ci/lib/dakota-receipt.sh"
ARTIFACT_DIR="${CI_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/omarchy-bootc-dakota-roundtrip}"
WORK_ROOT="${ROOT_DIR}/output/gate4-dakota"
DISK_SIZE="${DISK_SIZE:-32G}"
SSH_PORT="${SSH_PORT:-2233}"
SSH_USER="${SSH_USER:-omarchy}"
SSH_PASSWORD="${SSH_PASSWORD:-omarchy}"
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-360}"

# This is the reviewed current Dakota release. Updating it is an explicit
# source-freeze change, not an implicit tag lookup during a gate run.
DAKOTA_IMAGE_REF="${DAKOTA_IMAGE_REF:-ghcr.io/projectbluefin/dakota@sha256:ddab2e2d816976a8f181603987e76d1c992109f435b2abdf1eae76f40f7139f8}"
DAKOTA_TRACKING_REF="${DAKOTA_TRACKING_REF:-ghcr.io/projectbluefin/dakota:stable}"
DAKOTA_EXPECTED_DIGEST="sha256:ddab2e2d816976a8f181603987e76d1c992109f435b2abdf1eae76f40f7139f8"
QUATTRO_IMAGE_REF="${QUATTRO_IMAGE_REF:-}"
QUATTRO_TRACKING_REF="${QUATTRO_TRACKING_REF:-ghcr.io/joshyorko/omarchy-bootc:testing}"
QUATTRO_SOURCE_SHA="${QUATTRO_SOURCE_SHA:-}"

QCOW_PATH="${WORK_ROOT}/dakota-roundtrip.qcow2"
RAW_PATH="${WORK_ROOT}/dakota-roundtrip.raw"
DAKOTA_OVERLAY_OCI="${WORK_ROOT}/dakota-overlay-oci"
OVERLAY_CONTEXT="${WORK_ROOT}/dakota-overlay-context"
QEMU_PIDFILE="${WORK_ROOT}/qemu.pid"
QEMU_LOG="${WORK_ROOT}/qemu-serial.log"
QEMU_OVMF_VARS="${WORK_ROOT}/ovmf-vars.fd"

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=3
    -o LogLevel=ERROR
    -p "${SSH_PORT}"
)

die() {
    echo "ERROR: $*" >&2
    exit 1
}

fail() {
    local message="$1"
    capture_guest_diagnostics || true
    capture_host_diagnostics || true
    echo "ERROR: ${message}" >&2
    echo "Gate 4 receipts are in ${ARTIFACT_DIR}" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

valid_digest() {
    [[ "$1" =~ ^sha256:[[:xdigit:]]{64}$ ]]
}

valid_immutable_ref() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*@sha256:[[:xdigit:]]{64}$ ]]
}

valid_tracking_ref() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*:[A-Za-z0-9][A-Za-z0-9._-]*$ &&
       "$1" != *@sha256:* ]]
}

if [[ -z "${QUATTRO_IMAGE_REF}" ]]; then
    die 'QUATTRO_IMAGE_REF must be the accepted immutable Quattro image reference'
fi
valid_immutable_ref "${DAKOTA_IMAGE_REF}" || die "Dakota input is not immutable: ${DAKOTA_IMAGE_REF}"
valid_immutable_ref "${QUATTRO_IMAGE_REF}" || die "Quattro input is not immutable: ${QUATTRO_IMAGE_REF}"
valid_tracking_ref "${DAKOTA_TRACKING_REF}" || die "Dakota tracking ref is not mutable: ${DAKOTA_TRACKING_REF}"
valid_tracking_ref "${QUATTRO_TRACKING_REF}" || die "Quattro tracking ref is not mutable: ${QUATTRO_TRACKING_REF}"
DAKOTA_EXPECTED_REF="ghcr.io/projectbluefin/dakota@${DAKOTA_EXPECTED_DIGEST}"
[[ "${DAKOTA_IMAGE_REF}" == "${DAKOTA_EXPECTED_REF}" ]] ||
    die 'Dakota image ref does not match the repository-owned current release'
[[ "${DAKOTA_IMAGE_REF##*@}" == "${DAKOTA_EXPECTED_DIGEST}" ]] ||
    die 'Dakota image ref does not match the repository-owned current release digest'
QUATTRO_EXPECTED_DIGEST="${QUATTRO_IMAGE_REF##*@}"
valid_digest "${QUATTRO_EXPECTED_DIGEST}" || die 'Quattro ref has no valid immutable digest'
[[ -n "${QUATTRO_SOURCE_SHA}" && "${QUATTRO_SOURCE_SHA}" =~ ^[[:xdigit:]]{40}$ ]] ||
    die 'QUATTRO_SOURCE_SHA must identify the exact source commit used to publish the accepted image'

mkdir -p "${ARTIFACT_DIR}" "${WORK_ROOT}"
rm -rf "${DAKOTA_OVERLAY_OCI}" "${OVERLAY_CONTEXT}" "${RAW_PATH}" "${QCOW_PATH}"
mkdir -p "${OVERLAY_CONTEXT}"

if [[ "$(id -u)" == 0 ]]; then
    PODMAN=(podman)
else
    require_command sudo
    sudo -n true >/dev/null 2>&1 || die 'passwordless sudo is required for rootful bootc disk installation'
    PODMAN=(sudo podman)
fi

podman_cmd() {
    "${PODMAN[@]}" "$@"
}

find_first_existing_file() {
    local candidate
    for candidate in "$@"; do
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

OVMF_CODE_PATH="$(find_first_existing_file \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd || true)"
OVMF_VARS_TEMPLATE="$(find_first_existing_file \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd \
    /usr/share/edk2/ovmf/OVMF_VARS.fd || true)"
[[ -n "${OVMF_CODE_PATH}" && -n "${OVMF_VARS_TEMPLATE}" ]] ||
    die 'UEFI OVMF firmware is required for the Dakota VM gate'
cp "${OVMF_VARS_TEMPLATE}" "${QEMU_OVMF_VARS}"

run_guest() {
    sshpass -p "${SSH_PASSWORD}" ssh "${SSH_OPTS[@]}" "${SSH_USER}@127.0.0.1" "$@"
}

copy_to_guest() {
    local source="$1" destination="$2"
    sshpass -p "${SSH_PASSWORD}" scp -P "${SSH_PORT}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${source}" "${SSH_USER}@127.0.0.1:${destination}"
}

capture_guest_diagnostics() {
    if ! run_guest 'echo guest-up' >/dev/null 2>&1; then
        return 0
    fi
    run_guest 'sudo -n bootc status --format=json' \
        >"${ARTIFACT_DIR}/failure-bootc-status.json" 2>"${ARTIFACT_DIR}/failure-bootc-status.stderr" || true
    run_guest 'sudo -n systemctl --failed --no-pager --full' \
        >"${ARTIFACT_DIR}/failure-systemd-failed.txt" 2>&1 || true
    run_guest 'sudo -n journalctl -b --no-pager' \
        >"${ARTIFACT_DIR}/failure-journal.txt" 2>&1 || true
    run_guest 'id; sudo -n systemctl status sshd --no-pager --full' \
        >"${ARTIFACT_DIR}/failure-ssh-status.txt" 2>&1 || true
}

capture_host_diagnostics() {
    [[ -f "${QEMU_LOG}" ]] && cp "${QEMU_LOG}" "${ARTIFACT_DIR}/qemu-serial.log" || true
    [[ -f "${QCOW_PATH}" ]] && qemu-img info "${QCOW_PATH}" >"${ARTIFACT_DIR}/qcow-info.txt" 2>&1 || true
    [[ -f "${RAW_PATH}" ]] && qemu-img info "${RAW_PATH}" >"${ARTIFACT_DIR}/raw-info.txt" 2>&1 || true
}

cleanup() {
    capture_host_diagnostics || true
    if [[ -f "${QEMU_PIDFILE}" ]]; then
        kill "$(cat "${QEMU_PIDFILE}")" >/dev/null 2>&1 || true
        rm -f "${QEMU_PIDFILE}"
    fi
    rm -f "${QEMU_OVMF_VARS}"
}
trap cleanup EXIT

wait_for_guest() {
    local attempts=$((SSH_WAIT_SECONDS / 2))
    for _ in $(seq 1 "${attempts}"); do
        if run_guest 'echo ssh-up' >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

reboot_guest() {
    local before after
    before="$(run_guest 'cat /proc/sys/kernel/random/boot_id')" || return 1
    run_guest 'sudo -n systemctl reboot' >/dev/null 2>&1 || true
    for _ in $(seq 1 180); do
        sleep 2
        after="$(run_guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
        if [[ -n "${after}" && "${after}" != "${before}" ]]; then
            printf '%s\n' "${after}"
            return 0
        fi
    done
    return 1
}

record_backend() {
    local status_file="$1" label="$2" backend
    backend="$(jq -er -f "${ROOT_DIR}/scripts/ci/bootc-backend.jq" "${status_file}")" ||
        fail "${label} bootc status did not expose a booted image backend"
    printf '%s\n' "${backend}" >"${ARTIFACT_DIR}/${label}-backend.txt"
    printf '%s\n' "${backend}"
}

assert_status_digest() {
    local status_file="$1" expected="$2" label="$3" actual
    actual="$(jq -er '.status.booted.image.imageDigest // empty' "${status_file}")" ||
        fail "${label} bootc status has no booted image digest"
    [[ "${actual}" == "${expected}" ]] ||
        fail "${label} booted digest ${actual} differs from expected ${expected}"
}

pull_exact() {
    local ref="$1" expected="$2" label="$3" digest
    podman_cmd pull --quiet "${ref}" 2>&1 | tee "${ARTIFACT_DIR}/${label}-pull.log"
    digest="$(podman_cmd image inspect "${ref}" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
        | awk -F@ -v expected="${expected}" '$2 == expected { print $2; exit }')"
    [[ "${digest}" == "${expected}" ]] || fail "${label} did not resolve to ${expected}"
    printf '%s\n' "${digest}" >"${ARTIFACT_DIR}/${label}-digest.txt"
}

echo '==> Gate 4 inputs' | tee "${ARTIFACT_DIR}/gate4.log"
printf '%s\n' "${DAKOTA_IMAGE_REF}" >"${ARTIFACT_DIR}/dakota-input-ref.txt"
printf '%s\n' "${DAKOTA_EXPECTED_DIGEST}" >"${ARTIFACT_DIR}/dakota-input-digest.txt"
printf '%s\n' "${QUATTRO_IMAGE_REF}" >"${ARTIFACT_DIR}/quattro-accepted-ref.txt"
printf '%s\n' "${QUATTRO_TRACKING_REF}" >"${ARTIFACT_DIR}/quattro-tracking-ref.txt"
printf '%s\n' "${QUATTRO_SOURCE_SHA}" >"${ARTIFACT_DIR}/quattro-source-sha.txt"
jq -n \
    --arg dakota_ref "${DAKOTA_IMAGE_REF}" \
    --arg dakota_tracking_ref "${DAKOTA_TRACKING_REF}" \
    --arg dakota_digest "${DAKOTA_EXPECTED_DIGEST}" \
    --arg quattro_ref "${QUATTRO_IMAGE_REF}" \
    --arg quattro_tracking_ref "${QUATTRO_TRACKING_REF}" \
    --arg quattro_digest "${QUATTRO_EXPECTED_DIGEST}" \
    --arg source_sha "${QUATTRO_SOURCE_SHA}" \
    '{dakota:{immutable_ref:$dakota_ref,tracking_ref:$dakota_tracking_ref,digest:$dakota_digest},
      quattro:{accepted_immutable_ref:$quattro_ref,tracking_ref:$quattro_tracking_ref,digest:$quattro_digest,source_sha:$source_sha}}' \
    >"${ARTIFACT_DIR}/gate4-inputs.json"

echo '==> Pull the exact current Dakota source' | tee -a "${ARTIFACT_DIR}/gate4.log"
pull_exact "${DAKOTA_IMAGE_REF}" "${DAKOTA_EXPECTED_DIGEST}" dakota-source

cat >"${OVERLAY_CONTEXT}/Containerfile" <<EOF
FROM ${DAKOTA_IMAGE_REF}
COPY dakota-ci-firstboot.sh /usr/libexec/dakota-ci-firstboot
COPY dakota-ci-firstboot.service /usr/lib/systemd/system/dakota-ci-firstboot.service
RUN chmod 0755 /usr/libexec/dakota-ci-firstboot && \
    systemctl enable sshd.service dakota-ci-firstboot.service
EOF
cat >"${OVERLAY_CONTEXT}/dakota-ci-firstboot.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if ! getent group wheel >/dev/null; then
    groupadd wheel
fi
if ! id omarchy >/dev/null 2>&1; then
    useradd --uid 1000 --create-home --home-dir /var/home/omarchy \
        --groups wheel --shell /bin/bash omarchy
fi
usermod --append --groups wheel omarchy
printf 'omarchy:omarchy\n' | chpasswd
install -d -m 0755 -o omarchy -g omarchy /var/home/omarchy
printf 'dakota-source-marker\n' > /var/home/omarchy/.gate4-dakota-marker
chown omarchy:omarchy /var/home/omarchy/.gate4-dakota-marker
touch /var/lib/dakota-ci-firstboot-ready
EOF
cat >"${OVERLAY_CONTEXT}/dakota-ci-firstboot.service" <<'EOF'
[Unit]
Description=Create the Gate 4 disposable Dakota account
After=local-fs.target
Before=sshd.service
ConditionPathExists=!/var/lib/dakota-ci-firstboot-ready

[Service]
Type=oneshot
ExecStart=/usr/libexec/dakota-ci-firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
podman_cmd build --pull=never --format=oci --file "${OVERLAY_CONTEXT}/Containerfile" \
    --tag localhost/dakota-gate4:source "${OVERLAY_CONTEXT}" \
    2>&1 | tee "${ARTIFACT_DIR}/dakota-overlay-build.log"
podman_cmd run --rm --privileged --pull=never localhost/dakota-gate4:source \
    bootc container lint --fatal-warnings 2>&1 | tee "${ARTIFACT_DIR}/dakota-overlay-lint.log"
podman_cmd save --format=oci-dir --output "${DAKOTA_OVERLAY_OCI}" localhost/dakota-gate4:source \
    2>&1 | tee "${ARTIFACT_DIR}/dakota-overlay-export.log"
overlay_digest="$(jq -er '.manifests[0].digest' "${DAKOTA_OVERLAY_OCI}/index.json")"
valid_digest "${overlay_digest}" || fail 'Dakota acceptance overlay has no OCI manifest digest'
printf '%s\n' "${overlay_digest}" >"${ARTIFACT_DIR}/dakota-overlay-digest.txt"
chmod -R a+rX "${DAKOTA_OVERLAY_OCI}"

echo '==> Install the current Dakota source overlay to a blank disk' | tee -a "${ARTIFACT_DIR}/gate4.log"
truncate -s "${DISK_SIZE}" "${RAW_PATH}"
podman_cmd run --rm --privileged --pid=host --pull=never \
    -v /dev:/dev \
    -v /var/lib/containers:/var/lib/containers \
    -v /etc/containers:/etc/containers \
    -v "${WORK_ROOT}:/data/gate4" \
    localhost/dakota-gate4:source \
    bootc install to-disk \
        --source-imgref oci:/data/gate4/dakota-overlay-oci \
        --target-imgref "${DAKOTA_IMAGE_REF}" \
        --composefs-backend --via-loopback \
        --filesystem btrfs --wipe --bootloader systemd \
        /data/gate4/dakota-roundtrip.raw \
    2>&1 | tee "${ARTIFACT_DIR}/dakota-install-to-disk.log"
qemu-img convert -O qcow2 "${RAW_PATH}" "${QCOW_PATH}"

echo '==> Boot the installed Dakota source in UEFI QEMU' | tee -a "${ARTIFACT_DIR}/gate4.log"
QEMU_ACCEL=tcg
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU_ACCEL=kvm
fi
printf '%s\n' "${QEMU_ACCEL}" >"${ARTIFACT_DIR}/qemu-accelerator.txt"
qemu-system-x86_64 \
    -name omarchy-bootc-dakota-gate4 \
    -machine q35,accel="${QEMU_ACCEL}" \
    -cpu max -smp 2 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE_PATH}" \
    -drive if=pflash,format=raw,file="${QEMU_OVMF_VARS}" \
    -display none -serial file:"${QEMU_LOG}" -monitor none \
    -drive if=virtio,format=qcow2,file="${QCOW_PATH}" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
    -device virtio-net-pci,netdev=net0 \
    -daemonize -pidfile "${QEMU_PIDFILE}"

wait_for_guest || fail 'Dakota did not expose SSH after first boot'
run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/dakota-source-status.json" ||
    fail 'could not capture live Dakota bootc status'
record_backend "${ARTIFACT_DIR}/dakota-source-status.json" dakota-source
source_configured_ref="$(jq -er '.spec.image.image // empty' "${ARTIFACT_DIR}/dakota-source-status.json")" ||
    fail 'Dakota source status has no configured image reference'
[[ "${source_configured_ref}" == "${DAKOTA_IMAGE_REF}" ]] ||
    fail "Dakota source status configured ref is not the frozen Dakota image: ${source_configured_ref}"
jq -er '.status.booted.image.imageDigest // empty' "${ARTIFACT_DIR}/dakota-source-status.json" \
    >"${ARTIFACT_DIR}/dakota-overlay-booted-digest.txt" || fail 'Dakota source status has no booted digest'
assert_status_digest "${ARTIFACT_DIR}/dakota-source-status.json" "${DAKOTA_EXPECTED_DIGEST}" dakota-source
run_guest 'id -u omarchy && id -g omarchy && test -f /var/home/omarchy/.gate4-dakota-marker' \
    >"${ARTIFACT_DIR}/dakota-source-account.txt" || fail 'Dakota disposable account did not initialize'
run_guest 'sudo -n true && getent hosts github.com' \
    >"${ARTIFACT_DIR}/dakota-source-network.txt" || fail 'Dakota source sudo or networking check failed'

# Copy the real transition helper into the disposable source. This keeps the
# VM exercise on the same helper used by users while leaving the Dakota image
# itself untouched.
mkdir -p "${WORK_ROOT}/transition/custom/bootc"
cp "${ROOT_DIR}/transition/omarchy-transition.sh" "${WORK_ROOT}/transition/transition.sh"
cp "${ROOT_DIR}/custom/bootc/omarchy-bootc-common.sh" \
    "${WORK_ROOT}/transition/custom/bootc/omarchy-bootc-common.sh"
chmod 0755 "${WORK_ROOT}/transition/transition.sh"
copy_to_guest "${WORK_ROOT}/transition/transition.sh" /home/omarchy/omarchy-transition
copy_to_guest "${WORK_ROOT}/transition/custom/bootc/omarchy-bootc-common.sh" /home/omarchy/omarchy-bootc-common.sh
run_guest 'sudo -n install -D -m 0755 /home/omarchy/omarchy-transition /home/omarchy/transition/omarchy-transition.sh && \
    sudo -n install -D -m 0644 /home/omarchy/omarchy-bootc-common.sh /home/omarchy/custom/bootc/omarchy-bootc-common.sh'

run_guest 'printf "gate4-user-state\n" > /var/home/omarchy/.gate4-user-state && sha256sum /var/home/omarchy/.gate4-user-state' \
    >"${ARTIFACT_DIR}/source-user-state.sha256"
source_transition_env=(OMARCHY_TRANSITION_STATE_ROOT=/var/lib/omarchy-bootc/transitions/gate4-forward)
run_guest "sudo -n env ${source_transition_env[*]} /home/omarchy/transition/omarchy-transition.sh inspect-source" \
    >"${ARTIFACT_DIR}/dakota-inspect-source.txt" || fail 'live Dakota source inspection failed'
grep -Fq '"profile":"dakota"' "${ARTIFACT_DIR}/dakota-inspect-source.txt" ||
    fail 'live source inspection did not identify Dakota from authoritative status'

echo '==> Preflight, capture, and backup on live Dakota' | tee -a "${ARTIFACT_DIR}/gate4.log"
run_guest "sudo -n env ${source_transition_env[*]} /home/omarchy/transition/omarchy-transition.sh preflight '${QUATTRO_TRACKING_REF}'" \
    >"${ARTIFACT_DIR}/dakota-forward-preflight.txt" || fail 'Dakota forward preflight failed'
grep -Fq "target_resolved_digest=${QUATTRO_EXPECTED_DIGEST}" "${ARTIFACT_DIR}/dakota-forward-preflight.txt" ||
    fail 'forward preflight did not resolve the accepted Quattro digest'
run_guest "sudo -n env ${source_transition_env[*]} /home/omarchy/transition/omarchy-transition.sh capture-state" \
    >"${ARTIFACT_DIR}/dakota-forward-capture.txt" || fail 'Dakota forward capture failed'
run_guest "sudo -n env ${source_transition_env[*]} /home/omarchy/transition/omarchy-transition.sh backup" \
    >"${ARTIFACT_DIR}/dakota-forward-backup.txt" || fail 'Dakota forward backup failed'

echo '==> Switch Dakota -> Quattro and verify the exact staged/booted digest' | tee -a "${ARTIFACT_DIR}/gate4.log"
run_guest "sudo -n env ${source_transition_env[*]} /home/omarchy/transition/omarchy-transition.sh apply --confirm '${QUATTRO_TRACKING_REF}'" \
    >"${ARTIFACT_DIR}/dakota-forward-apply.txt" || fail 'Dakota forward switch failed'
run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/quattro-staged-status.json" || fail 'could not capture staged Quattro status'
jq -e --arg digest "${QUATTRO_EXPECTED_DIGEST}" \
    '.status.staged.image.imageDigest == $digest' "${ARTIFACT_DIR}/quattro-staged-status.json" >/dev/null ||
    fail 'staged Quattro digest was not the accepted immutable artifact'
reboot_guest || fail 'Quattro reboot was not observed'
run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/quattro-booted-status.json" || fail 'could not capture Quattro boot status'
record_backend "${ARTIFACT_DIR}/quattro-booted-status.json" quattro-booted
assert_status_digest "${ARTIFACT_DIR}/quattro-booted-status.json" "${QUATTRO_EXPECTED_DIGEST}" quattro

for _ in $(seq 1 180); do
    adoption_status="$(run_guest 'sudo -n grep "^status=" /var/lib/omarchy-bootc/adoption/state.env 2>/dev/null | cut -d= -f2 || true')"
    [[ "${adoption_status}" == complete ]] && break
    [[ "${adoption_status}" == failed || "${adoption_status}" == account-conflict ]] &&
        fail "live Quattro adoption ended in ${adoption_status}"
    sleep 2
done
run_guest 'sudo -n grep -Fxq status=complete /var/lib/omarchy-bootc/adoption/state.env' \
    >"${ARTIFACT_DIR}/quattro-adoption.txt" || fail 'live Quattro adoption did not complete'
run_guest 'id -u omarchy; id -g omarchy; test -f /var/home/omarchy/.gate4-user-state; sha256sum /var/home/omarchy/.gate4-user-state' \
    >"${ARTIFACT_DIR}/quattro-user-state.txt" || fail 'Quattro did not preserve the Dakota user/home state'
run_guest 'sudo -n true && getent hosts github.com' \
    >"${ARTIFACT_DIR}/quattro-sudo-network.txt" || fail 'Quattro sudo or networking check failed'

# The fixture-level recovery test exercises account-created/password and retry
# boundaries independently. Its result is retained beside the live adoption
# receipt so the two proofs cannot be conflated.
bash "${ROOT_DIR}/tests/test-adoption-resume.sh" >"${ARTIFACT_DIR}/adoption-recovery-contract.log" 2>&1 ||
    fail 'adoption recovery contract did not pass'

echo '==> Switch Quattro -> Dakota and verify state preservation' | tee -a "${ARTIFACT_DIR}/gate4.log"
run_guest 'sudo -n systemctl disable dakota-ci-firstboot.service 2>/dev/null || true; \
    sudo -n rm -f /etc/systemd/system/multi-user.target.wants/dakota-ci-firstboot.service'
reverse_env=(OMARCHY_TRANSITION_STATE_ROOT=/var/lib/omarchy-bootc/transitions/gate4-reverse)
run_guest "sudo -n env ${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh inspect-source" \
    >"${ARTIFACT_DIR}/quattro-inspect-source.txt" || fail 'live Quattro source inspection failed'
grep -Fq '"profile":"omarchy"' "${ARTIFACT_DIR}/quattro-inspect-source.txt" ||
    fail 'live Quattro source inspection did not identify Omarchy from status'
run_guest "sudo -n env ${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh preflight '${DAKOTA_TRACKING_REF}'" \
    >"${ARTIFACT_DIR}/quattro-reverse-preflight.txt" || fail 'Quattro reverse preflight failed'
grep -Fq "target_resolved_digest=${DAKOTA_EXPECTED_DIGEST}" "${ARTIFACT_DIR}/quattro-reverse-preflight.txt" ||
    fail 'reverse preflight did not resolve the frozen Dakota digest'
run_guest "sudo -n env ${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh capture-state" \
    >"${ARTIFACT_DIR}/quattro-reverse-capture.txt" || fail 'Quattro reverse capture failed'
run_guest "sudo -n env ${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh backup" \
    >"${ARTIFACT_DIR}/quattro-reverse-backup.txt" || fail 'Quattro reverse backup failed'
run_guest "sudo -n env ${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh apply --confirm '${DAKOTA_TRACKING_REF}'" \
    >"${ARTIFACT_DIR}/quattro-reverse-apply.txt" || fail 'Quattro reverse switch failed'
run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/dakota-reverse-staged-status.json" || fail 'could not capture staged Dakota status'
jq -e --arg digest "${DAKOTA_EXPECTED_DIGEST}" \
    '.status.staged.image.imageDigest == $digest' "${ARTIFACT_DIR}/dakota-reverse-staged-status.json" >/dev/null ||
    fail 'staged Dakota digest was not the frozen current release'
reboot_guest || fail 'Dakota reverse reboot was not observed'
run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/dakota-reverse-status.json" || fail 'could not capture final Dakota status'
record_backend "${ARTIFACT_DIR}/dakota-reverse-status.json" dakota-reverse
assert_status_digest "${ARTIFACT_DIR}/dakota-reverse-status.json" "${DAKOTA_EXPECTED_DIGEST}" dakota-reverse
run_guest 'id -u omarchy; id -g omarchy; test -f /var/home/omarchy/.gate4-user-state; sha256sum /var/home/omarchy/.gate4-user-state' \
    >"${ARTIFACT_DIR}/dakota-reverse-user-state.txt" || fail 'Dakota did not preserve the Quattro user/home state'
run_guest 'sudo -n true && getent hosts github.com' \
    >"${ARTIFACT_DIR}/dakota-reverse-sudo-network.txt" || fail 'Dakota reverse sudo or networking check failed'

source_backend="$(<"${ARTIFACT_DIR}/dakota-source-backend.txt")"
quattro_backend="$(<"${ARTIFACT_DIR}/quattro-booted-backend.txt")"
reverse_backend="$(<"${ARTIFACT_DIR}/dakota-reverse-backend.txt")"
write_gate4_receipt \
    "${ARTIFACT_DIR}/gate4-dakota-roundtrip.receipt.json" \
    "${DAKOTA_IMAGE_REF}" "${DAKOTA_TRACKING_REF}" "${DAKOTA_EXPECTED_DIGEST}" \
    "${overlay_digest}" "${QUATTRO_IMAGE_REF}" "${QUATTRO_TRACKING_REF}" \
    "${QUATTRO_EXPECTED_DIGEST}" "${QUATTRO_SOURCE_SHA}" \
    "${source_backend}" "${quattro_backend}" "${reverse_backend}"
printf 'GATE4_RESULT=passed\nreceipt=%s\n' "${ARTIFACT_DIR}/gate4-dakota-roundtrip.receipt.json"
