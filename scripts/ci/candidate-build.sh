#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${CANDIDATE_ARTIFACT_DIR:-${RUNNER_TEMP:-${ROOT_DIR}/output}/omarchy-bootc-candidate}"
LOG_DIR="${ARTIFACT_DIR}/logs"
IMAGE_REF="${CANDIDATE_IMAGE_REF:-localhost/omarchy-bootc:candidate}"
MIN_FREE_GIB="${CANDIDATE_MIN_FREE_GIB:-12}"
MAX_LOG_BYTES="${CANDIDATE_MAX_LOG_BYTES:-1048576}"

mkdir -p "${LOG_DIR}"

trim_logs() {
    local log_file=""
    local size=0
    local tmp_file=""

    while IFS= read -r -d '' log_file; do
        size="$(wc -c <"${log_file}")"
        if ((size > MAX_LOG_BYTES)); then
            tmp_file="${log_file}.trimmed"
            tail -c "${MAX_LOG_BYTES}" "${log_file}" >"${tmp_file}"
            mv -f "${tmp_file}" "${log_file}"
        fi
    done < <(find "${LOG_DIR}" -type f -print0)
}

capture_failure_state() {
    {
        printf 'head='
        git -C "${ROOT_DIR}" rev-parse --verify HEAD || true
        git -C "${ROOT_DIR}" status --short || true
        df -h "${ROOT_DIR}" || true
        if command -v sudo >/dev/null 2>&1; then
            sudo -n podman system df || true
        fi
    } >"${LOG_DIR}/failure-state.log" 2>&1
}

on_exit() {
    local status="$?"
    if ((status != 0)); then
        capture_failure_state
    fi
    trim_logs
    exit "${status}"
}
trap on_exit EXIT

die() {
    echo "ERROR: $*" >&2
    return 1
}

run_logged() {
    local name="$1"
    shift
    local log_file="${LOG_DIR}/${name}.log"
    {
        printf '+ '
        printf '%q ' "$@"
        printf '\n'
    } | tee "${log_file}"
    set +e
    "$@" 2>&1 | tee -a "${log_file}"
    local command_status="${PIPESTATUS[0]}"
    set -e
    return "${command_status}"
}

read_pin() {
    local path="$1"
    local value=""
    [[ -f "${path}" ]] || die "missing upstream pin: ${path}"
    value="$(tr -d '\r\n' <"${path}")"
    [[ "${value}" =~ ^[[:xdigit:]]{40}$ ]] || die "invalid upstream pin in ${path}"
    printf '%s\n' "${value}"
}

read_arg() {
    local name="$1"
    sed -nE "s/^ARG ${name}=\\\"([^\\\"]+)\\\"$/\\1/p" "${ROOT_DIR}/Containerfile" | head -n 1
}

require_commands() {
    local command=""
    for command in awk date df find git jq podman sha256sum stat sudo tar timeout tr; do
        command -v "${command}" >/dev/null 2>&1 || die "required command unavailable: ${command}"
    done
}

preflight() {
    local rootless=""
    local free_kib=""
    local minimum_kib=$((MIN_FREE_GIB * 1024 * 1024))
    local kvm_state="unavailable"

    require_commands
    cd "${ROOT_DIR}"

    if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        kvm_state="accessible"
    elif [[ -e /dev/kvm ]]; then
        kvm_state="present-but-inaccessible"
    fi

    free_kib="$(df -Pk "${ROOT_DIR}" | awk 'NR == 2 {print $4}')"
    [[ "${free_kib}" =~ ^[0-9]+$ ]] || die "unable to determine free disk space"
    ((free_kib >= minimum_kib)) || die "only $((free_kib / 1024 / 1024)) GiB free; need at least ${MIN_FREE_GIB} GiB"

    rootless="$(sudo -n podman info --format '{{.Host.Security.Rootless}}')"
    [[ "${rootless}" == "false" ]] || die "sudo podman is not rootful (rootless=${rootless})"
    run_logged podman-info sudo -n podman info --format 'version={{.Version.Version}} rootless={{.Host.Security.Rootless}} graphroot={{.Store.GraphRoot}}'

    {
        printf 'source_head=%s\n' "$(git rev-parse HEAD)"
        printf 'root_dir=%s\n' "${ROOT_DIR}"
        printf 'free_disk_gib=%s\n' "$((free_kib / 1024 / 1024))"
        printf 'minimum_free_disk_gib=%s\n' "${MIN_FREE_GIB}"
        printf 'kvm=%s\n' "${kvm_state}"
        printf 'rootful_podman=%s\n' "${rootless}"
    } | tee "${LOG_DIR}/preflight.txt"
}

build_candidate() {
    local head_sha=""
    local head_short=""
    local quattro_revision=""
    local iso_revision=""
    local bootcrew_revision=""
    local bootc_revision=""
    local arch_bootstrap_ref=""
    local bootcrew_source=""
    local bootc_source=""
    local omarchy_source=""
    local omarchy_iso_source=""
    local omarchy_version=""
    local tracking_ref="ghcr.io/joshyorko/omarchy-bootc:testing"
    local image_id=""
    local manifest_digest=""
    local archive_sha256=""
    local archive_path=""
    local receipt_path=""
    local candidate_stem=""
    local created_at=""
    local archive_size=""

    cd "${ROOT_DIR}"
    head_sha="$(git rev-parse --verify HEAD)"
    [[ "${head_sha}" =~ ^[[:xdigit:]]{40}$ ]] || die "checked-out HEAD is not a full commit SHA"
    head_short="${head_sha:0:12}"
    quattro_revision="$(read_pin sources/omarchy-quattro.revision)"
    iso_revision="$(read_pin sources/omarchy-iso-quattro.revision)"
    bootcrew_revision="$(read_pin vendor/bootcrew/REVISION)"
    bootc_revision="$(read_pin vendor/bootcrew/BOOTC_REVISION)"
    arch_bootstrap_ref="$(read_arg ARCH_BOOTSTRAP_REF)"
    bootcrew_source="$(tr -d '\r\n' <vendor/bootcrew/SOURCE)"
    bootc_source="$(tr -d '\r\n' <vendor/bootcrew/BOOTC_SOURCE)"
    omarchy_source="$(tr -d '\r\n' <sources/omarchy-quattro.source)"
    omarchy_iso_source="$(tr -d '\r\n' <sources/omarchy-iso-quattro.source)"
    omarchy_version="$(tr -d '\r\n' <sources/omarchy-quattro-version)"
    [[ -n "${arch_bootstrap_ref}" && -n "${bootcrew_source}" && -n "${bootc_source}" && -n "${omarchy_source}" && -n "${omarchy_iso_source}" && -n "${omarchy_version}" ]] || die "missing Containerfile or upstream source metadata"

    run_logged build sudo -n podman build \
        --pull=missing \
        --format=oci \
        --target final \
        --tag "${IMAGE_REF}" \
        --label "org.opencontainers.image.revision=${head_sha}" \
        --label "org.opencontainers.image.version=candidate-${head_short}" \
        --label "com.omarchy.candidate.head=${head_sha}" \
        --label "com.omarchy.candidate.quattro=${quattro_revision}" \
        --label "com.omarchy.candidate.quattro-version=${omarchy_version}" \
        --label "com.omarchy.candidate.bootcrew=${bootcrew_revision}" \
        --label "com.omarchy.candidate.bootc=${bootc_revision}" \
        "${ROOT_DIR}"

    run_logged fatal-lint sudo -n podman run --rm --pull=never --privileged "${IMAGE_REF}" bootc container lint --fatal-warnings

    image_id="$(sudo -n podman image inspect "${IMAGE_REF}" --format '{{.Id}}')"
    [[ "${image_id}" =~ ^(sha256:)?[[:xdigit:]]{64}$ ]] || die "image ID is not immutable: ${image_id}"

    candidate_stem="omarchy-bootc-candidate-head-${head_sha}-quattro-${quattro_revision:0:12}-iso-${iso_revision:0:12}-bootcrew-${bootcrew_revision:0:12}-bootc-${bootc_revision:0:12}"
    archive_path="${ARTIFACT_DIR}/${candidate_stem}.oci.tar"
    receipt_path="${ARTIFACT_DIR}/${candidate_stem}.receipt.json"
    run_logged export sudo -n podman save --format=oci-archive --output "${archive_path}" "${IMAGE_REF}"
    archive_sha256="$(sha256sum "${archive_path}" | awk '{print $1}')"
    manifest_digest="$(tar -xOf "${archive_path}" index.json | jq -er '.manifests[0].digest')"
    [[ "${manifest_digest}" =~ ^sha256:[[:xdigit:]]{64}$ ]] || die "OCI archive has no immutable manifest digest"
    archive_size="$(stat -c '%s' "${archive_path}")"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg schema 'omarchy-bootc.candidate/v1' \
        --arg repository "${GITHUB_REPOSITORY:-}" \
        --arg event "${GITHUB_EVENT_NAME:-}" \
        --arg head "${head_sha}" \
        --arg image "${IMAGE_REF}" \
        --arg archive "$(basename "${archive_path}")" \
        --arg archive_sha256 "sha256:${archive_sha256}" \
        --arg archive_size "${archive_size}" \
        --arg manifest_digest "${manifest_digest}" \
        --arg image_id "${image_id}" \
        --arg created_at "${created_at}" \
        --arg arch_bootstrap_ref "${arch_bootstrap_ref}" \
        --arg omarchy_source "${omarchy_source}" \
        --arg omarchy_iso_source "${omarchy_iso_source}" \
        --arg bootcrew_source "${bootcrew_source}" \
        --arg bootcrew_revision "${bootcrew_revision}" \
        --arg bootc_source "${bootc_source}" \
        --arg bootc_revision "${bootc_revision}" \
        --arg quattro_revision "${quattro_revision}" \
        --arg iso_revision "${iso_revision}" \
        --arg omarchy_version "${omarchy_version}" \
        --arg tracking_ref "${tracking_ref}" \
        --arg lint_result 'passed:bootc container lint --fatal-warnings' \
        '{schema:$schema, repository:$repository, event:$event, source_head:$head,
          image:$image, archive:$archive, archive_sha256:$archive_sha256,
          archive_size_bytes:($archive_size|tonumber), manifest_digest:$manifest_digest,
          image_id:$image_id, created_at:$created_at, lint_result:$lint_result,
          upstream_pins:{arch_bootstrap_ref:$arch_bootstrap_ref,
            omarchy_source:$omarchy_source, omarchy_iso_source:$omarchy_iso_source,
            bootcrew_source:$bootcrew_source, bootcrew_revision:$bootcrew_revision,
            bootc_source:$bootc_source, bootc_revision:$bootc_revision,
            omarchy_quattro_revision:$quattro_revision,
            omarchy_iso_quattro_revision:$iso_revision,
            omarchy_version:$omarchy_version, tracking_ref:$tracking_ref}}' \
        >"${receipt_path}"

    printf 'Candidate archive: %s\nReceipt: %s\n' "${archive_path}" "${receipt_path}"
}

case "${1:-}" in
    preflight)
        preflight
        ;;
    build)
        build_candidate
        ;;
    *)
        echo "Usage: $0 {preflight|build}" >&2
        exit 2
        ;;
esac
