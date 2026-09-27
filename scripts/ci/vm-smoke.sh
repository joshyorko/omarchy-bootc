#!/usr/bin/env bash
set -euo pipefail

IMAGE_REF="${1:-}"
if [[ -z "${IMAGE_REF}" ]]; then
    echo "Usage: $0 <image-ref>"
    exit 1
fi

SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-omarchy}"
SSH_PASSWORD="${SSH_PASSWORD:-omarchy}"
GUEST_HOME="${GUEST_HOME:-/home/${SSH_USER}}"
VM_PROFILE="${VM_PROFILE:-omarchy}"
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
    sshpass -p "${SSH_PASSWORD}" ssh "${SSH_OPTS[@]}" "${SSH_USER}@127.0.0.1" "$@"
}

wait_for_guest_reboot() {
    local before_boot_id="$1" after_boot_id=""
    for _ in $(seq 1 180); do
        sleep 2
        after_boot_id="$(run_guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
        if [[ -n "${after_boot_id}" && "${after_boot_id}" != "${before_boot_id}" ]]; then
            printf '%s\n' "${after_boot_id}"
            return 0
        fi
    done
    return 1
}

reboot_guest() {
    local before_boot_id
    before_boot_id="$(run_guest 'cat /proc/sys/kernel/random/boot_id')"
    run_guest 'sudo -n systemctl reboot' || true
    wait_for_guest_reboot "${before_boot_id}"
}

build_lifecycle_revision() {
    local lifecycle_dir="$1" base_ref="$2" b_ref="$3" archive="$4"
    mkdir -p "${lifecycle_dir}"
    cat >"${lifecycle_dir}/Containerfile" <<EOF
FROM ${base_ref}
RUN printf '%s\\n' lifecycle-b > /usr/lib/omarchy-bootc/lifecycle-b
EOF
    podman build --pull=never --format=oci --file "${lifecycle_dir}/Containerfile" \
        --tag "${b_ref}" "${lifecycle_dir}" \
        2>&1 | tee "${ARTIFACT_DIR}/lifecycle-b-build.log"
    podman run --rm --pull=never --privileged "${b_ref}" \
        bootc container lint --fatal-warnings \
        2>&1 | tee "${ARTIFACT_DIR}/lifecycle-b-lint.log"
    podman save --format=oci-archive --output "${archive}" "${b_ref}" \
        2>&1 | tee "${ARTIFACT_DIR}/lifecycle-b-export.log"
    tar -xOf "${archive}" index.json | jq -er '.manifests[0].digest' \
        >"${ARTIFACT_DIR}/lifecycle-b-digest.txt"
    sha256sum "${archive}" >"${ARTIFACT_DIR}/lifecycle-b-archive.sha256"
}

snapshot_user_plugin_state() {
    local label="$1"
    local output="${ARTIFACT_DIR}/user-plugin-state-${label}.tsv"
    local digest_line=""

    run_guest 'set -euo pipefail
snapshot_root() {
    local root="$1"
    local file rel digest
    if [[ ! -e "$root" ]]; then
        printf "missing\t%s\n" "$root"
        return 0
    fi
    printf "root\t%s\n" "$root"
    if [[ -d "$root" ]]; then
        while IFS= read -r -d "" file; do
            rel="${file#"$HOME"/}"
            digest="$(sha256sum "$file")"
            digest="${digest%% *}"
            printf "%s\t%s\n" "$rel" "$digest"
        done < <(find "$root" -type f -print0 | sort -z)
    else
        digest="$(sha256sum "$root")"
        digest="${digest%% *}"
        printf "%s\t%s\n" "$root" "$digest"
    fi
}
for root in \
    "$HOME/.config/omarchy/plugins" \
    "$HOME/.config/omarchy/defaults" \
    "$HOME/.agents/skills" \
    "$HOME/.claude/skills" \
    "$HOME/.codex/skills" \
    "$HOME/.pi/agent/skills" \
    "$HOME/.hermes/skills"; do
    snapshot_root "$root"
done' >"$output"

    [[ -s "$output" ]] || fail "user/plugin state snapshot is empty: ${label}"
    digest_line="$(sha256sum "$output")"
    printf '%s\n' "${digest_line%% *}" >"${output}.sha256"
    printf '%s\n' "${digest_line%% *}"
}

snapshot_pacman_state() {
    local label="$1"
    local output="${ARTIFACT_DIR}/pacman-state-${label}.tsv"
    local digest_line=""

    run_guest 'set -euo pipefail
snapshot_tree() {
    local kind="$1"
    local root="$2"
    local file digest
    [[ -d "$root" ]] || return 0
    printf "%s-root\t%s\n" "$kind" "$root"
    while IFS= read -r -d "" file; do
        digest="$(sha256sum "$file")"
        digest="${digest%% *}"
        printf "%s\t%s\t%s\n" "$kind" "$file" "$digest"
    done < <(find "$root" -type f -print0 | sort -z)
}
db_seen=0
log_seen=0
for root in /var/lib/pacman/local /usr/lib/sysimage/var/lib/pacman/local; do
    if [[ -d "$root" ]]; then
        db_seen=1
        snapshot_tree pacman-db "$root"
    fi
done
for file in /var/log/pacman.log /usr/lib/sysimage/var/log/pacman.log; do
    if [[ -f "$file" ]]; then
        log_seen=1
        digest="$(sha256sum "$file")"
        digest="${digest%% *}"
        printf "pacman-log\t%s\t%s\n" "$file" "$digest"
    fi
done
[[ "$db_seen" == 1 ]] || { echo "pacman database was not found" >&2; exit 1; }
[[ "$log_seen" == 1 ]] || { echo "pacman log was not found" >&2; exit 1; }
package_set="$(pacman -Q)"
digest="$(printf "%s\n" "$package_set" | sha256sum)"
printf "pacman-package-set\t%s\n" "${digest%% *}"' >"$output"

    [[ -s "$output" ]] || fail "pacman DB/log snapshot is empty: ${label}"
    digest_line="$(sha256sum "$output")"
    printf '%s\n' "${digest_line%% *}" >"${output}.sha256"
    printf '%s\n' "${digest_line%% *}"
}

record_configured_tracking_ref() {
    local label="$1"
    local status_file="$2"
    local enforce="${3:-0}"
    local tracking=""

    tracking="$(jq -er '.spec.image.image | strings | select(length > 0)' "$status_file")" || \
        fail "bootc status has no configured image ref: ${label}"
    printf '%s\n' "$tracking" >"${ARTIFACT_DIR}/configured-ref-${label}.txt"

    if [[ "$enforce" == 1 ]]; then
        if [[ -n "${OMARCHY_EXPECTED_TRACKING_REF:-}" ]]; then
            [[ "$tracking" == "$OMARCHY_EXPECTED_TRACKING_REF" ]] || \
                fail "configured tracking ref mismatch: expected ${OMARCHY_EXPECTED_TRACKING_REF}, found ${tracking}"
        elif [[ "${OMARCHY_ASSERT_TESTING_REF:-0}" == 1 ]]; then
            [[ "$tracking" == *:testing ]] || \
                fail "configured image ref is not the testing stream: ${tracking}"
        fi
    fi
    printf '%s\n' "$tracking"
}

run_lifecycle_acceptance() {
    [[ "${VM_PROFILE}" == omarchy ]] || return 0

    local lifecycle_dir="${RUNNER_TEMP:-/tmp}/omarchy-lifecycle-b"
    local b_archive="${lifecycle_dir}/lifecycle-b.oci.tar"
    local b_ref="localhost/omarchy-bootc:acceptance-b"
    local a_digest="${expected_digest}"
    local b_digest=""
    local b_path="${GUEST_HOME}/lifecycle-b.oci.tar"
    local update_status=0
    local a_tracking_ref=""
    local tracking_assertion="recorded-only"
    local a_state_hash=""
    local b_state_hash=""
    local rollback_state_hash=""
    local update_state_hash=""
    local pacman_before_hash=""
    local pacman_after_update_hash=""
    local pacman_after_reboot_hash=""
    local update_trace_hash=""
    local final_tracking_ref=""

    [[ "$a_digest" =~ ^sha256:[[:xdigit:]]{64}$ ]] || fail "lifecycle A has no immutable OCI digest"
    mkdir -p "$lifecycle_dir"

    build_lifecycle_revision "$lifecycle_dir" "$IMAGE_REF" "$b_ref" "$b_archive"
    b_digest="$(cat "$ARTIFACT_DIR/lifecycle-b-digest.txt")"
    [[ "$b_digest" =~ ^sha256:[[:xdigit:]]{64}$ ]] || fail "lifecycle B has no immutable OCI digest"
    printf 'A=%s\nB=%s\n' "$a_digest" "$b_digest" >"$ARTIFACT_DIR/lifecycle-ab.txt"

    sshpass -p "$SSH_PASSWORD" scp -P "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$b_archive" "$SSH_USER@127.0.0.1:$b_path"
    run_guest "sha256sum '$b_path'" >"$ARTIFACT_DIR/guest-lifecycle-b-archive.sha256"

    # Record A before any transition. The testing-ref assertion is only
    # enforced when the caller provides the expected production origin; local
    # OCI acceptance sources remain valid and are recorded without guessing.
    run_guest 'sudo -n bootc status --format=json' >"$ARTIFACT_DIR/lifecycle-a-before-status.json"
    a_tracking_ref="$(record_configured_tracking_ref lifecycle-a-before "$ARTIFACT_DIR/lifecycle-a-before-status.json" 1)"
    if [[ -n "${OMARCHY_EXPECTED_TRACKING_REF:-}" || "${OMARCHY_ASSERT_TESTING_REF:-0}" == 1 ]]; then
        tracking_assertion="passed"
    fi
    a_state_hash="$(snapshot_user_plugin_state a-before)"

    # Gate 3: A -> B. This direct switch is the controlled exact-artifact
    # transition; Gate 5 below deliberately does not pre-stage B this way.
    run_guest "sudo -n bootc switch --transport oci-archive --download-only 'oci-archive:$b_path'" \
        2>&1 | tee "$ARTIFACT_DIR/lifecycle-stage-b.log"
    run_guest 'sudo -n bootc status --format=json' >"$ARTIFACT_DIR/lifecycle-staged-status.json"
    jq -e --arg digest "$b_digest" '.status.staged.image.imageDigest == $digest' \
        "$ARTIFACT_DIR/lifecycle-staged-status.json" >/dev/null \
        || fail "bootc did not stage exact lifecycle B digest"

    reboot_guest || fail "lifecycle B reboot was not observed"
    run_guest 'sudo -n bootc status --format=json' >"$ARTIFACT_DIR/lifecycle-b-booted-status.json"
    jq -e --arg digest "$b_digest" '.status.booted.image.imageDigest == $digest' \
        "$ARTIFACT_DIR/lifecycle-b-booted-status.json" >/dev/null \
        || fail "lifecycle B did not boot"
    run_guest 'test "$(cat /usr/lib/omarchy-bootc/lifecycle-b)" = lifecycle-b' \
        || fail "lifecycle B payload was not present after reboot"
    b_state_hash="$(snapshot_user_plugin_state b-booted)"
    cmp -s "$ARTIFACT_DIR/user-plugin-state-a-before.tsv" \
        "$ARTIFACT_DIR/user-plugin-state-b-booted.tsv" \
        || fail "user/plugin state changed across A -> B"

    # Roll back to A and prove the same user/plugin state survives the
    # deployment boundary.
    run_guest 'sudo -n bootc rollback' 2>&1 | tee "$ARTIFACT_DIR/lifecycle-rollback.log"
    reboot_guest || fail "rollback reboot was not observed"
    run_guest 'sudo -n bootc status --format=json' >"$ARTIFACT_DIR/lifecycle-a-rollback-status.json"
    jq -e --arg digest "$a_digest" '.status.booted.image.imageDigest == $digest' \
        "$ARTIFACT_DIR/lifecycle-a-rollback-status.json" >/dev/null \
        || fail "rollback did not restore exact lifecycle A digest"
    rollback_state_hash="$(snapshot_user_plugin_state a-rollback)"
    cmp -s "$ARTIFACT_DIR/user-plugin-state-a-before.tsv" \
        "$ARTIFACT_DIR/user-plugin-state-a-rollback.tsv" \
        || fail "user/plugin state did not survive rollback"
    run_guest 'test -d "$HOME/.config/omarchy/plugins"' \
        || fail "user/plugin state directory did not survive rollback"

    # Gate 5: call the real Omarchy updater from the A deployment. There is
    # intentionally no direct bootc switch here: the updater's own
    # upgrade --check/upgrade path must discover and stage the controlled B.
    rm -f "$ARTIFACT_DIR/update-stage-b.log"
    run_guest 'sudo -n rm -f /run/omarchy-bootc-bootc-trace.log'
    cat >"$lifecycle_dir/bootc-trace" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> /run/omarchy-bootc-bootc-trace.log
exec /usr/bin/bootc "$@"
EOF
    sshpass -p "$SSH_PASSWORD" scp -P "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$lifecycle_dir/bootc-trace" "$SSH_USER@127.0.0.1:$GUEST_HOME/bootc-trace"
    run_guest "sudo -n install -m 0755 '$GUEST_HOME/bootc-trace' /usr/local/bin/bootc-trace"

    pacman_before_hash="$(snapshot_pacman_state before-update)"
    set +e
    run_guest 'env OMARCHY_BOOTC_BIN=/usr/local/bin/bootc-trace /usr/local/bin/omarchy update -y' \
        2>&1 | tee "$ARTIFACT_DIR/omarchy-update.log"
    update_status="${PIPESTATUS[0]}"
    set -e
    (( update_status == 0 )) || fail "omarchy update did not complete the staged bootc transaction"
    run_guest 'sudo -n cat /run/omarchy-bootc-bootc-trace.log' >"$ARTIFACT_DIR/omarchy-update-bootc-trace.log"
    grep -Fq 'upgrade --check' "$ARTIFACT_DIR/omarchy-update-bootc-trace.log" \
        || fail "omarchy update did not invoke bootc upgrade --check"
    grep -Fxq 'upgrade' "$ARTIFACT_DIR/omarchy-update-bootc-trace.log" \
        || fail "omarchy update did not invoke a bootc upgrade operation"
    if grep -Eq '(^|[[:space:]])pacman([[:space:]]|$)' \
        "$ARTIFACT_DIR/omarchy-update-bootc-trace.log"; then
        fail "omarchy update invoked pacman through the bootc trace"
    fi

    pacman_after_update_hash="$(snapshot_pacman_state after-update)"
    [[ "$pacman_before_hash" == "$pacman_after_update_hash" ]] \
        || fail "omarchy update changed the pacman DB or log snapshot"

    reboot_guest || fail "update reboot was not observed"
    run_guest 'sudo -n bootc status --format=json' >"$ARTIFACT_DIR/update-booted-status.json"
    jq -e --arg digest "$b_digest" '.status.booted.image.imageDigest == $digest' \
        "$ARTIFACT_DIR/update-booted-status.json" >/dev/null \
        || fail "the updater did not boot the staged exact B digest"
    update_state_hash="$(snapshot_user_plugin_state b-update)"
    cmp -s "$ARTIFACT_DIR/user-plugin-state-a-before.tsv" \
        "$ARTIFACT_DIR/user-plugin-state-b-update.tsv" \
        || fail "user/plugin state did not survive the bootc update"
    pacman_after_reboot_hash="$(snapshot_pacman_state after-update-reboot)"
    [[ "$pacman_before_hash" == "$pacman_after_reboot_hash" ]] \
        || fail "reboot changed the pacman DB or log snapshot"
    final_tracking_ref="$(record_configured_tracking_ref update-booted "$ARTIFACT_DIR/update-booted-status.json" 0)"
    update_trace_hash="$(sha256sum "$ARTIFACT_DIR/omarchy-update-bootc-trace.log")"
    update_trace_hash="${update_trace_hash%% *}"

    jq -n \
        --arg schema "omarchy-bootc.gates-3-5/v2" \
        --arg source_sha "${GITHUB_SHA:-unknown}" \
        --arg image_ref "$IMAGE_REF" \
        --arg a_digest "$a_digest" \
        --arg b_digest "$b_digest" \
        --arg initial_tracking_ref "$a_tracking_ref" \
        --arg final_tracking_ref "$final_tracking_ref" \
        --arg tracking_assertion "$tracking_assertion" \
        --arg a_state_hash "$a_state_hash" \
        --arg b_state_hash "$b_state_hash" \
        --arg rollback_state_hash "$rollback_state_hash" \
        --arg update_state_hash "$update_state_hash" \
        --arg pacman_before_hash "$pacman_before_hash" \
        --arg pacman_after_update_hash "$pacman_after_update_hash" \
        --arg pacman_after_reboot_hash "$pacman_after_reboot_hash" \
        --arg update_trace_hash "$update_trace_hash" \
        --arg receipt "passed" \
        '{
          schema: $schema,
          source_sha: $source_sha,
          image_ref: $image_ref,
          artifacts: {A: {digest: $a_digest}, B: {digest: $b_digest}},
          configured_tracking_ref: {
            initial: $initial_tracking_ref,
            final: $final_tracking_ref,
            assertion: $tracking_assertion
          },
          user_plugin_state_hashes: {
            a_before: $a_state_hash,
            b_booted: $b_state_hash,
            a_rollback: $rollback_state_hash,
            b_update: $update_state_hash
          },
          gate5: {
            pre_stage: "none",
            updater: "omarchy update -y",
            bootc_trace_sha256: $update_trace_hash,
            pacman_db_log_before: $pacman_before_hash,
            pacman_db_log_after_update: $pacman_after_update_hash,
            pacman_db_log_after_reboot: $pacman_after_reboot_hash
          },
          receipt: $receipt
        }' >"$ARTIFACT_DIR/gate-3-5.receipt.json"
    jq -e '.receipt == "passed" and .gate5.pre_stage == "none"' \
        "$ARTIFACT_DIR/gate-3-5.receipt.json" >/dev/null \
        || fail "Gate 3/5 JSON receipt was not complete"

    printf '%s\n' passed >"$ARTIFACT_DIR/gate-3-5.receipt"
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

if [[ "${VM_PROFILE}" == omarchy ]]; then
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
fi

echo "::group::Run in-VM smoke checks"
if [[ "${VM_PROFILE}" == omarchy ]]; then
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
else
    run_guest 'set -euo pipefail
id
systemctl is-active sshd
test -r /etc/os-release
test -x /usr/bin/bootc' || fail "In-VM generic bootc checks failed."
fi
echo "::endgroup::"

run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/first-boot-status.json"
jq -e 'type == "object"' "${ARTIFACT_DIR}/first-boot-status.json" >/dev/null
jq -e --arg digest "${expected_digest}" '.status.booted.image.imageDigest == $digest' \
    "${ARTIFACT_DIR}/first-boot-status.json" >/dev/null \
    || fail "Booted acceptance digest differs from the installed OCI manifest."

acceptance_status=0
if [[ "${VM_PROFILE}" == omarchy && -n "${UPSTREAM_ACCEPTANCE_DIR:-}" ]]; then
    # scp uses -P rather than ssh's -p. Transfer only tests, never the source .git.
    sshpass -p "${SSH_PASSWORD}" scp -r -P "${SSH_PORT}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${UPSTREAM_ACCEPTANCE_DIR}/test" "${SSH_USER}@127.0.0.1:upstream-acceptance-test"
    run_guest 'mkdir -p "$HOME/upstream-acceptance/test"; cp -a "$HOME/upstream-acceptance-test/." "$HOME/upstream-acceptance/test/"'
    if ! run_guest 'env OMARCHY_ACCEPTANCE_DIR="$HOME/acceptance-receipts/upstream" OMARCHY_ACCEPTANCE_TEST_TIMEOUT=120 timeout 20m bash "$HOME/upstream-acceptance/test/acceptance"' \
        2>&1 | tee "${ARTIFACT_DIR}/upstream-acceptance.log"; then
        acceptance_status=1
    fi
fi

if [[ "${VM_PROFILE}" == omarchy && -n "${NATIVE_ACCEPTANCE_SCRIPT:-}" ]]; then
    sshpass -p "${SSH_PASSWORD}" scp -P "${SSH_PORT}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${NATIVE_ACCEPTANCE_SCRIPT}" "${SSH_USER}@127.0.0.1:guest-native-acceptance.sh"
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

if [[ "${VM_PROFILE}" == omarchy ]]; then
    run_lifecycle_acceptance
fi
capture_host_diagnostics
capture_guest_diagnostics
((acceptance_status == 0)) || fail "One or more graphical/native acceptance checks failed; inspect individual receipts."
echo "Requested first-boot/runtime and A/B lifecycle checks passed. Dakota round-trip remains a separate transition gate."
