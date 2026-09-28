#!/usr/bin/env bash
# Remote command strings intentionally defer guest-side expansion; source paths
# are resolved from SCRIPT_DIR at runtime.
# shellcheck disable=SC2016,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/runtime-artifacts.sh
source "${SCRIPT_DIR}/lib/runtime-artifacts.sh"
# shellcheck source=lib/upstream-acceptance.sh
source "${SCRIPT_DIR}/lib/upstream-acceptance.sh"

# The harness, QEMU, and receipts belong to the runner. Select only Podman's
# store explicitly; legacy rootless callers still hand off the install image.
VM_PODMAN_ROOTFUL="${VM_PODMAN_ROOTFUL:-0}"
[[ "${VM_PODMAN_ROOTFUL}" == 0 || "${VM_PODMAN_ROOTFUL}" == 1 ]] || {
    echo 'VM_PODMAN_ROOTFUL must be 0 or 1' >&2
    exit 2
}
host_root() {
    if (( EUID == 0 )); then "$@"; else sudo -n -- "$@"; fi
}
host_podman() {
    if [[ "${VM_PODMAN_ROOTFUL}" == 1 ]]; then
        host_root podman "$@"
    else
        podman "$@"
    fi
}

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

# Fail before image export/disk installation, not when a later runtime gate
# first reaches an unavailable runner-side tool.
for command_name in bash cat cp date dirname env find grep head id jq mkdir \
    mktemp podman python3 qemu-img qemu-system-x86_64 rm seq sha256sum \
    sleep sort ssh sshpass scp stat tar tee timeout truncate uname; do
    command -v "${command_name}" >/dev/null || {
        echo "Required host command unavailable: ${command_name}" >&2
        exit 1
    }
done
if (( EUID != 0 )); then
    command -v sudo >/dev/null
    sudo -n true
fi
if [[ "${VM_PROFILE}" == omarchy && "${RUN_LIFECYCLE_ACCEPTANCE:-1}" == 1 ]]; then
    command -v skopeo >/dev/null || {
        echo 'Skopeo is required for the exact-digest lifecycle registry fixture' >&2
        exit 1
    }
fi
SOURCE_OCI_DIR="output/source-oci"
ARTIFACT_DIR="${CI_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/omarchy-bootc-artifacts}"
QEMU_WORK_DIR=""
QEMU_PIDFILE=""
QEMU_LOG=""
QEMU_AS_ROOT=0
QEMU_OVMF_VARS=""
REGISTRY_CONTAINER=""
REGISTRY_PORT=""
HOST_REGISTRY_REF=""
GUEST_REGISTRY_REF=""
INSTALL_TARGET_ARGS=()
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

    if (( EUID == 0 )) || [[ "${VM_PODMAN_ROOTFUL}" == 1 ]]; then
        echo "Using the selected rootful image store; no handoff is needed."
        return
    fi


    rootless_id="$(podman image inspect "${image_ref}" --format '{{.Id}}')"
    if [[ -z "${rootless_id}" ]]; then
        echo "Unable to locate rootless image for ${image_ref}"
        exit 1
    fi

    rootful_id="$(host_root podman image inspect "${image_ref}" --format '{{.Id}}' 2>/dev/null || true)"
    if [[ "${rootful_id}" == "${rootless_id}" ]]; then
        return
    fi
    if ! command -v machinectl >/dev/null 2>&1; then
        echo "machinectl is required for podman image scp when copying into rootful podman"
        exit 1
    fi

    copy_tmp="$(mktemp -d "${QEMU_WORK_DIR}/podman-scp.XXXXXXXX")"
    local copy_status=0
    host_root env TMPDIR="${copy_tmp}" podman image scp \
        "$(id -u)@localhost::${image_ref}" \
        "root@localhost::${image_ref}" || copy_status=$?
    host_root rm -rf -- "${copy_tmp}"
    return "${copy_status}"
}


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
    host_podman build --pull=never --format=oci --file "${lifecycle_dir}/Containerfile" \
        --tag "${b_ref}" "${lifecycle_dir}" \
        2>&1 | tee "${ARTIFACT_DIR}/lifecycle-b-build.log"
    host_podman run --rm --pull=never --privileged "${b_ref}" \
        bootc container lint --fatal-warnings \
        2>&1 | tee "${ARTIFACT_DIR}/lifecycle-b-lint.log"
    host_podman save --format=oci-archive "${b_ref}" >"${archive}" \
        2>"${ARTIFACT_DIR}/lifecycle-b-export.log"
    tar -xOf "${archive}" index.json | jq -er '.manifests[0].digest' \
        >"${ARTIFACT_DIR}/lifecycle-b-digest.txt"
    sha256sum "${archive}" >"${ARTIFACT_DIR}/lifecycle-b-archive.sha256"
}

pacman_db_fingerprint() {
    # Hash the actual configured database, not a possibly absent legacy path
    # or just its format-version file. Missing/empty databases fail closed.
    run_guest 'sudo -n bash -s' <<'EOF'
set -euo pipefail
db="$(pacman-conf DBPath)"
test -n "$db"
cd "$db"
test -d local
find local -mindepth 2 -maxdepth 2 -name desc -type f -print -quit | grep -q .
find local -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
EOF
}

publish_lifecycle_image() {
    local source="$1" digest="$2" stage="$3" actual
    skopeo copy --preserve-digests --dest-tls-verify=false \
        "${source}" "docker://${HOST_REGISTRY_REF}" \
        2>&1 | tee "${ARTIFACT_DIR}/${stage}-registry-copy.log"
    skopeo inspect --tls-verify=false --raw "docker://${HOST_REGISTRY_REF}" \
        >"${ARTIFACT_DIR}/${stage}-registry-manifest.json"
    actual="$(sha256sum "${ARTIFACT_DIR}/${stage}-registry-manifest.json")"
    [[ "sha256:${actual%% *}" == "${digest}" ]] \
        || fail "registry did not preserve exact ${stage} manifest"
}

start_lifecycle_registry() {
    # This fixture is private to the runner and QEMU's host gateway, never a
    # production image publication. The selected product image is unchanged.
    REGISTRY_CONTAINER="$(host_root podman run -d --pull=missing \
        -p 127.0.0.1::5000 docker.io/library/registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373)"
    host_root podman inspect "${REGISTRY_CONTAINER}" \
        >"${ARTIFACT_DIR}/lifecycle-registry-container.json"
    REGISTRY_PORT="$(host_root podman port "${REGISTRY_CONTAINER}" 5000/tcp)"
    REGISTRY_PORT="${REGISTRY_PORT##*:}"
    [[ "${REGISTRY_PORT}" =~ ^[0-9]+$ ]] || fail "registry has no mapped host port"
    HOST_REGISTRY_REF="127.0.0.1:${REGISTRY_PORT}/omarchy:acceptance"
    GUEST_REGISTRY_REF="10.0.2.2:${REGISTRY_PORT}/omarchy:acceptance"
    python3 - "${REGISTRY_PORT}" <<'PY'
import socket
import sys
import time
for attempt in range(60):
    try:
        with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1):
            break
    except OSError:
        time.sleep(0.5)
else:
    raise SystemExit("acceptance registry did not become reachable")
PY
    publish_lifecycle_image "oci:${SOURCE_OCI_DIR}" "${expected_digest}" lifecycle-a
    INSTALL_TARGET_ARGS=(--target-imgref "${GUEST_REGISTRY_REF}")
    printf '%s\n' "${GUEST_REGISTRY_REF}" >"${ARTIFACT_DIR}/lifecycle-tracking-ref.txt"
}

verify_lifecycle_user_state() {
    local stage="$1"
    run_guest 'test -d "$HOME/.config/omarchy/plugins"' \
        || fail "user/plugin state did not survive ${stage}"
    if [[ -n "${NATIVE_ACCEPTANCE_SCRIPT:-}" ]]; then
        run_guest 'env OMARCHY_ACCEPTANCE_DIR="$HOME/acceptance-receipts/native" timeout 5m bash "$HOME/guest-native-acceptance.sh" verify' \
            2>&1 | tee "${ARTIFACT_DIR}/native-${stage}.log"
        run_guest 'tar -C "$HOME/acceptance-receipts" -czf - native' \
            >"${ARTIFACT_DIR}/native-${stage}-receipts.tar.gz"
    fi
}

verify_update_finalized() {
    # Observe the actual login-triggered unit, never manually run migrations.
    run_guest 'bash -s' <<'EOF'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
for ((attempt=0; attempt<120; attempt++)); do
    if [[ ! -e "$HOME/.local/state/omarchy-bootc/pending-update" ]] &&
        [[ "$(systemctl --user show omarchy-bootc-finalize.service -p Result --value)" == success ]] &&
        [[ "$(systemctl --user show omarchy-bootc-finalize.service -p ExecMainStatus --value)" == 0 ]] &&
        [[ "$(systemctl --user show omarchy-bootc-finalize.service -p ExecMainStartTimestampMonotonic --value)" =~ ^[1-9][0-9]*$ ]]; then
        journalctl --user -b -u omarchy-bootc-finalize.service --no-pager
        exit 0
    fi
    sleep 2
done
systemctl --user status omarchy-bootc-finalize.service --no-pager || true
journalctl --user -b -u omarchy-bootc-finalize.service --no-pager || true
exit 1
EOF
}

run_lifecycle_acceptance() {
    [[ "${RUN_LIFECYCLE_ACCEPTANCE:-1}" == 1 ]] || return 0

    local lifecycle_dir="${QEMU_WORK_DIR}/lifecycle-b"
    local b_archive="${lifecycle_dir}/lifecycle-b.oci.tar"
    local b_ref="localhost/omarchy-bootc:acceptance-b"
    local a_digest="${expected_digest}" b_digest=""
    local -a update_status
    # Only this disposable guest registry endpoint is HTTP. Both bootc and
    # the real updater's skopeo digest lookup consume containers' same policy.
    run_guest 'sudo -n install -d -m 0755 /etc/containers/registries.conf.d'
    run_guest 'sudo -n tee /etc/containers/registries.conf.d/omarchy-acceptance.conf >/dev/null' <<EOF
[[registry]]
location = "10.0.2.2:${REGISTRY_PORT}"
insecure = true
EOF

    build_lifecycle_revision "${lifecycle_dir}" "${IMAGE_REF}" "${b_ref}" "${b_archive}"
    b_digest="$(cat "${ARTIFACT_DIR}/lifecycle-b-digest.txt")"
    [[ "${b_digest}" =~ ^sha256:[[:xdigit:]]{64}$ ]] || fail "lifecycle B has no immutable OCI digest"
    [[ "${b_digest}" != "${a_digest}" ]] || fail "lifecycle B is identical to A"
    printf 'A=%s\nB=%s\n' "${a_digest}" "${b_digest}" >"${ARTIFACT_DIR}/lifecycle-ab.txt"

    run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/update-before-status.json"
    jq -e --arg digest "${a_digest}" --arg ref "${GUEST_REGISTRY_REF}" \
        '.status.booted.image.imageDigest == $digest and .status.staged == null
         and .spec.image.transport == "registry" and .spec.image.image == $ref' \
        "${ARTIFACT_DIR}/update-before-status.json" >/dev/null \
        || fail "updater must start on exact A with no staged deployment and the fixture tracking ref"
    publish_lifecycle_image "oci-archive:${b_archive}" "${b_digest}" lifecycle-b

    # Gate 5 discovers and stages B exclusively through the real updater.
    # No bootc switch, prestaged deployment, synthetic status, or fake cache.
    pacman_db_fingerprint >"${ARTIFACT_DIR}/pacman-db-before.txt"
    [[ -s "${ARTIFACT_DIR}/pacman-db-before.txt" ]] || fail "pacman database fingerprint is empty"
    cat >"${lifecycle_dir}/bootc-trace" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if (( EUID != 0 )); then exec sudo -n -- "$0" "$@"; fi
printf '%s\n' "$*" >> /run/omarchy-bootc-update-trace/calls.log
exec /usr/bin/bootc "$@"
EOF
    sshpass -p "${SSH_PASSWORD}" scp -P "${SSH_PORT}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${lifecycle_dir}/bootc-trace" "${SSH_USER}@127.0.0.1:${GUEST_HOME}/bootc-trace"
    run_guest "sudo -n install -d -m 0755 /run/omarchy-bootc-update-trace &&
        sudo -n install -m 0755 '${GUEST_HOME}/bootc-trace' /run/omarchy-bootc-update-trace/bootc &&
        sudo -n install -m 0600 /dev/null /run/omarchy-bootc-update-trace/calls.log"
    set +e
    run_guest '/usr/local/bin/omarchy update -y' \
        2>&1 | tee "${ARTIFACT_DIR}/omarchy-update.log"
    update_status=("${PIPESTATUS[@]}")
    set -e
    (( update_status[0] == 0 )) || fail "omarchy update did not complete the A-to-B bootc transaction"
    (( update_status[1] == 0 )) || fail "could not retain the updater log"
    run_guest 'sudo -n cat /run/omarchy-bootc-update-trace/calls.log' >"${ARTIFACT_DIR}/omarchy-update-bootc-trace.log"
    grep -Fxq 'upgrade --check' "${ARTIFACT_DIR}/omarchy-update-bootc-trace.log" \
        || fail "omarchy update did not invoke bootc upgrade --check"
    grep -Fxq 'upgrade' "${ARTIFACT_DIR}/omarchy-update-bootc-trace.log" \
        || fail "omarchy update did not invoke bootc upgrade to stage B"
    run_guest 'test -s "$HOME/.local/state/omarchy-bootc/pending-update" &&
        cat "$HOME/.local/state/omarchy-bootc/pending-update"' \
        >"${ARTIFACT_DIR}/update-pending-marker.txt"
    grep -Fxq "expected_digest=${b_digest}" "${ARTIFACT_DIR}/update-pending-marker.txt" \
        || fail "updater did not persist the exact B transaction marker"
    pacman_db_fingerprint >"${ARTIFACT_DIR}/pacman-db-after.txt"
    cmp -s "${ARTIFACT_DIR}/pacman-db-before.txt" "${ARTIFACT_DIR}/pacman-db-after.txt" \
        || fail "omarchy update changed the pacman database"
    run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/update-staged-status.json"
    jq -e --arg digest "${b_digest}" \
        '.status.staged.image.imageDigest == $digest and .status.staged.downloadOnly == false' \
        "${ARTIFACT_DIR}/update-staged-status.json" >/dev/null \
        || fail "the updater did not stage exact unlocked B"
    reboot_guest || fail "lifecycle B update reboot was not observed"
    run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/update-booted-status.json"
    cp "${ARTIFACT_DIR}/update-booted-status.json" "${ARTIFACT_DIR}/lifecycle-b-booted-status.json"
    jq -e --arg digest "${b_digest}" '.status.booted.image.imageDigest == $digest' \
        "${ARTIFACT_DIR}/update-booted-status.json" >/dev/null \
        || fail "the updater did not boot exact lifecycle B"
    run_guest 'test "$(cat /usr/lib/omarchy-bootc/lifecycle-b)" = lifecycle-b' \
        || fail "lifecycle B payload was not present after reboot"
    verify_update_finalized 2>&1 | tee "${ARTIFACT_DIR}/update-finalized.log"
    verify_lifecycle_user_state update-b

    run_guest 'sudo -n bootc rollback' 2>&1 | tee "${ARTIFACT_DIR}/lifecycle-rollback.log"
    reboot_guest || fail "rollback reboot was not observed"
    run_guest 'sudo -n bootc status --format=json' >"${ARTIFACT_DIR}/lifecycle-a-rollback-status.json"
    jq -e --arg digest "${a_digest}" '.status.booted.image.imageDigest == $digest' \
        "${ARTIFACT_DIR}/lifecycle-a-rollback-status.json" >/dev/null \
        || fail "rollback did not restore exact lifecycle A digest"
    verify_lifecycle_user_state rollback-a
    printf '%s\n' passed >"${ARTIFACT_DIR}/gate-3-5.receipt"
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
    write_artifact guest-update-trace.log run_guest 'sudo -n cat /run/omarchy-bootc-update-trace/calls.log'
    write_artifact guest-update-finalize.log run_guest 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"; systemctl --user status omarchy-bootc-finalize.service --no-pager; journalctl --user -b -u omarchy-bootc-finalize.service --no-pager'
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

    echo "${message}" >&2
    capture_host_diagnostics || true
    capture_guest_diagnostics || true
    if [[ -f "${QEMU_LOG}" ]]; then
        echo "QEMU serial log (tail):"
        tail -n 200 "${QEMU_LOG}" || true
    fi
    echo "Diagnostics written to ${ARTIFACT_DIR}"
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    capture_guest_diagnostics
    if [[ -f "${QEMU_PIDFILE}" ]]; then
        if (( QEMU_AS_ROOT )); then
            host_root kill "$(cat "${QEMU_PIDFILE}")" >/dev/null 2>&1
        else
            kill "$(cat "${QEMU_PIDFILE}")" >/dev/null 2>&1
        fi
    fi
    if [[ -n "${REGISTRY_CONTAINER}" ]]; then
        host_root podman logs "${REGISTRY_CONTAINER}" >"${ARTIFACT_DIR}/lifecycle-registry.log" 2>&1
        host_root podman rm -f "${REGISTRY_CONTAINER}" >/dev/null || {
            echo "Could not remove the acceptance registry fixture" >&2
            (( status != 0 )) || status=1
        }
    fi
    capture_host_diagnostics
    # Never let diagnostic failure hide the original program status; failure
    # to make successful receipts readable must itself fail the harness.
    normalize_runtime_artifacts "${ARTIFACT_DIR}" || {
        echo "Could not make runtime artifacts runner-readable" >&2
        (( status != 0 )) || status=1
    }
    [[ -z "${QEMU_WORK_DIR}" ]] || rm -rf -- "${QEMU_WORK_DIR}"
    exit "${status}"
}
trap cleanup EXIT

mkdir -p "${ARTIFACT_DIR}"
normalize_runtime_artifacts "${ARTIFACT_DIR}"
QEMU_WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/omarchy-bootc-vm.XXXXXXXX")"
QEMU_PIDFILE="${QEMU_WORK_DIR}/qemu.pid"
QEMU_LOG="${QEMU_WORK_DIR}/qemu.log"
QEMU_OVMF_VARS="${QEMU_WORK_DIR}/ovmf-vars.fd"
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

mkdir -p output
host_root rm -rf output/qcow2 output/raw "${SOURCE_OCI_DIR}"

echo "::group::Preflight bootc image state"
IMAGE_ID="$(host_podman image inspect "${IMAGE_REF}" --format '{{.Id}}')"
echo "Resolved image ref: ${IMAGE_REF}" | tee "${ARTIFACT_DIR}/image-ref.txt"
echo "Resolved image ID: ${IMAGE_ID}" | tee "${ARTIFACT_DIR}/image-id.txt"

host_podman run --rm --pull=never "${IMAGE_REF}" bash -lc '
set -euo pipefail
echo "bootc=$(bootc --version | head -n1)"
bootc container lint --fatal-warnings
find /usr/lib/modules -mindepth 1 -maxdepth 2 \( -name initramfs.img -o -name vmlinuz \) | sort
' 2>&1 | tee "${ARTIFACT_DIR}/image-preflight.log"
if [[ "${VM_PROFILE}" == omarchy ]]; then
    host_podman run --rm --pull=never "${IMAGE_REF}" \
        /usr/lib/omarchy-bootc/acceptance-dependencies.sh overlay \
        2>&1 | tee "${ARTIFACT_DIR}/overlay-dependencies.log"
fi
echo "::endgroup::"

echo "::group::Prepare rootful image for bootc install"
rootful_copy_image "${IMAGE_REF}" \
    2>&1 | tee "${ARTIFACT_DIR}/rootful-image-copy.log"
echo "::endgroup::"

echo "::group::Export explicit install source image"
mkdir -p "${SOURCE_OCI_DIR}"
# Stream into runner-created files; rootful podman --output can create 0600
# root-owned archives/layouts that the rest of the harness cannot read.
host_podman save --format oci-archive "${IMAGE_REF}" \
    2>"${ARTIFACT_DIR}/source-oci-export.log" \
    | tar --no-same-owner --no-same-permissions -C "${SOURCE_OCI_DIR}" -xf -
cp "${SOURCE_OCI_DIR}/index.json" "${ARTIFACT_DIR}/acceptance-oci-index.json"
expected_digest="$(jq -er '.manifests[0].digest' "${SOURCE_OCI_DIR}/index.json")"
SOURCE_IMGREF="oci:/data/${SOURCE_OCI_DIR}"
echo "Using source imgref: ${SOURCE_IMGREF}" | tee "${ARTIFACT_DIR}/source-imgref.txt"
if [[ "${VM_PROFILE}" == omarchy && "${RUN_LIFECYCLE_ACCEPTANCE:-1}" == 1 ]]; then
    start_lifecycle_registry
fi
echo "::endgroup::"

echo "::group::Generate qcow2 via bootc install-to-disk"
mkdir -p "$(dirname "${RAW_PATH}")" "$(dirname "${QCOW_PATH}")"
truncate -s "${DISK_SIZE}" "${RAW_PATH}"
echo "Sparse disk size: ${DISK_SIZE}" | tee "${ARTIFACT_DIR}/disk-size.txt"

host_root podman run --rm --privileged --pid=host --pull=never \
    -v /dev:/dev \
    -v /var/lib/containers:/var/lib/containers \
    -v /etc/containers:/etc/containers \
    -v "${PWD}:/data" \
    "${IMAGE_REF}" \
    bootc install to-disk --source-imgref "${SOURCE_IMGREF}" \
        "${INSTALL_TARGET_ARGS[@]}" \
        --composefs-backend --via-loopback --filesystem btrfs --wipe --bootloader systemd "/data/${RAW_PATH}" \
    2>&1 | tee "${ARTIFACT_DIR}/bootc-install.log"

qemu-img convert -O qcow2 "${RAW_PATH}" "${QCOW_PATH}"
echo "::endgroup::"

if [[ ! -f "${QCOW_PATH}" ]]; then
    fail "Expected qcow2 image not found at ${QCOW_PATH}"
fi

echo "::group::Boot qcow2 in headless QEMU"
QEMU_ACCEL="tcg"
QEMU_COMMAND=(qemu-system-x86_64)
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU_ACCEL="kvm"
    echo "KVM is available and accessible." | tee "${ARTIFACT_DIR}/kvm-capability.txt"
elif [[ -c /dev/kvm ]] && host_root test -r /dev/kvm && host_root test -w /dev/kvm; then
    QEMU_ACCEL="kvm"
    QEMU_AS_ROOT=1
    QEMU_COMMAND=(host_root qemu-system-x86_64)
    echo "KVM requires root; elevate QEMU only, not the harness." | tee "${ARTIFACT_DIR}/kvm-capability.txt"
elif [[ -e /dev/kvm ]]; then
    echo "KVM device exists but is not accessible; falling back to software emulation." \
        | tee -a "${ARTIFACT_DIR}/qemu-accel.txt"
    echo "KVM exists but is inaccessible." | tee "${ARTIFACT_DIR}/kvm-capability.txt"
else
    echo "KVM device is absent; using software emulation." | tee "${ARTIFACT_DIR}/kvm-capability.txt"
fi
echo "Using QEMU accelerator: ${QEMU_ACCEL}" | tee -a "${ARTIFACT_DIR}/qemu-accel.txt"

# Retain runner ownership even when only QEMU needs root to open /dev/kvm.
: >"${QEMU_LOG}"
: >"${QEMU_PIDFILE}"
"${QEMU_COMMAND[@]}" \
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
    run_guest '/usr/lib/omarchy-bootc/acceptance-dependencies.sh guest' \
        2>&1 | tee "${ARTIFACT_DIR}/guest-dependencies.log"
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
    if ! run_upstream_acceptance \
        "${UPSTREAM_ACCEPTANCE_DIR}" "${ARTIFACT_DIR}" \
        "${SSH_USER}" "${SSH_PORT}" "${SSH_PASSWORD}"; then
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
