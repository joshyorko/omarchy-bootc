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
        capture_failure_state || true
    fi
    trim_logs || true
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
    local statuses=("${PIPESTATUS[@]}")
    set -e
    ((statuses[0] == 0)) || return "${statuses[0]}"
    return "${statuses[1]}"
}

# The runner opens the archive; rootful Podman never owns upload inputs.
export_archive() {
    local archive="$1" image="$2"
    # The runner owns the upload file; sudo only elevates Podman.
    # shellcheck disable=SC2024
    sudo -n podman save --format=oci-archive "${image}" >"${archive}"
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
    local graphroot=""
    local graph_free_kib=""
    local minimum_kib=$((MIN_FREE_GIB * 1024 * 1024))
    local kvm_state="unavailable"

    require_commands
    cd "${ROOT_DIR}"

    if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        kvm_state="accessible"
    elif [[ -e /dev/kvm ]]; then
        kvm_state="present-but-inaccessible"
    fi

    free_kib="$(df -Pk "${ARTIFACT_DIR}" | awk 'NR == 2 {print $4}')"
    [[ "${free_kib}" =~ ^[0-9]+$ ]] || die "unable to determine export store free disk space"
    ((free_kib >= minimum_kib)) || die "export store has only $((free_kib / 1024 / 1024)) GiB free; need at least ${MIN_FREE_GIB} GiB"

    rootless="$(sudo -n podman info --format '{{.Host.Security.Rootless}}')"
    [[ "${rootless}" == "false" ]] || die "sudo podman is not rootful (rootless=${rootless})"
    graphroot="$(sudo -n podman info --format '{{.Store.GraphRoot}}')"
    [[ -n "${graphroot}" ]] || die "unable to determine Podman graphroot"
    graph_free_kib="$(sudo -n df -Pk "${graphroot}" | awk 'NR == 2 {print $4}')"
    [[ "${graph_free_kib}" =~ ^[0-9]+$ ]] || die "unable to determine graphroot free disk space"
    ((graph_free_kib >= minimum_kib)) || die "Podman graphroot ${graphroot} has only $((graph_free_kib / 1024 / 1024)) GiB free; need at least ${MIN_FREE_GIB} GiB"
    run_logged podman-info sudo -n podman info --format 'version={{.Version.Version}} rootless={{.Host.Security.Rootless}} graphroot={{.Store.GraphRoot}}'

    {
        printf 'source_head=%s\n' "$(git rev-parse HEAD)"
        printf 'root_dir=%s\n' "${ROOT_DIR}"
        printf 'artifact_dir=%s\n' "${ARTIFACT_DIR}"
        printf 'graphroot=%s\n' "${graphroot}"
        printf 'free_disk_gib=%s\n' "$((free_kib / 1024 / 1024))"
        printf 'graphroot_free_disk_gib=%s\n' "$((graph_free_kib / 1024 / 1024))"
        printf 'minimum_free_disk_gib=%s\n' "${MIN_FREE_GIB}"
        printf 'kvm=%s\n' "${kvm_state}"
        printf 'rootful_podman=%s\n' "${rootless}"
    } | tee "${LOG_DIR}/preflight.txt"
    run_logged stage-parent-binding bash "${ROOT_DIR}/scripts/ci/probe-stage-parent-binding.sh"
}

verify_stage_ancestry() {
    local parent_ref="$1" child_ref="$2" relation="$3"
    local parent_layers="" child_layers=""
    parent_layers="$(sudo -n podman image inspect "${parent_ref}" --format '{{json .RootFS.Layers}}')"
    child_layers="$(sudo -n podman image inspect "${child_ref}" --format '{{json .RootFS.Layers}}')"
    python3 - "${parent_layers}" "${child_layers}" "${relation}" <<'PY'
import json, sys
parent = json.loads(sys.argv[1])
child = json.loads(sys.argv[2])
relation = sys.argv[3]
if not isinstance(parent, list) or not isinstance(child, list) or not parent:
    raise SystemExit(f"ERROR: empty or invalid layer DiffIDs for {relation}")
if len(child) < len(parent) or child[:len(parent)] != parent:
    raise SystemExit(
        f"ERROR: stage ancestry broken for {relation}: "
        f"parent has {len(parent)} layers, child has {len(child)} layers with mismatched prefix"
    )
print(f"Verified stage ancestry ({relation}): {len(parent)} -> {len(child)} layers")
PY
}

record_stage_receipt() {
    local target="$1"
    local image_ref="$2"
    local schema="$3"
    local receipt_stem="$4"
    local parent_target="$5"
    local parent_image_id="$6"
    local sibling_note="$7"
    local image_id=""
    local layer_count=""
    local receipt_path=""
    local created_at=""
    local head_sha=""
    local quattro_revision=""
    local iso_revision=""
    local bootcrew_revision=""
    local bootc_revision=""
    local bootc_version=""
    local arch_bootstrap_ref=""
    local omarchy_source=""
    local omarchy_iso_source=""
    local omarchy_version=""
    local tracking_ref="ghcr.io/joshyorko/omarchy-bootc:testing"

    head_sha="$(git -C "${ROOT_DIR}" rev-parse --verify HEAD)"
    quattro_revision="$(read_pin "${ROOT_DIR}/sources/omarchy-quattro.revision")"
    iso_revision="$(read_pin "${ROOT_DIR}/sources/omarchy-iso-quattro.revision")"
    bootcrew_revision="$(read_pin "${ROOT_DIR}/vendor/bootcrew/REVISION")"
    bootc_revision="$(read_pin "${ROOT_DIR}/vendor/bootcrew/BOOTC_REVISION")"
    bootc_version="$(tr -d '\r\n' <"${ROOT_DIR}/vendor/bootcrew/BOOTC_VERSION")"
    arch_bootstrap_ref="$(read_arg ARCH_BOOTSTRAP_REF)"
    omarchy_source="$(tr -d '\r\n' <"${ROOT_DIR}/sources/omarchy-quattro.source")"
    omarchy_iso_source="$(tr -d '\r\n' <"${ROOT_DIR}/sources/omarchy-iso-quattro.source")"
    omarchy_version="$(tr -d '\r\n' <"${ROOT_DIR}/sources/omarchy-quattro-version")"

    image_id="$(sudo -n podman image inspect "${image_ref}" --format '{{.Id}}')"
    [[ "${image_id}" =~ ^(sha256:)?[[:xdigit:]]{64}$ ]] \
        || die "${target} image ID is not immutable: ${image_id}"
    layer_count="$(sudo -n podman image inspect "${image_ref}" --format '{{len .RootFS.Layers}}')"
    receipt_path="${ARTIFACT_DIR}/${receipt_stem}.receipt.json"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg schema "${schema}" \
        --arg source_sha "${head_sha}" \
        --arg target "${target}" \
        --arg image "${image_ref}" \
        --arg image_id "${image_id}" \
        --arg layer_count "${layer_count}" \
        --arg created_at "${created_at}" \
        --arg parent_target "${parent_target}" \
        --arg parent_image_id "${parent_image_id}" \
        --arg verification_sibling "${sibling_note}" \
        --arg arch_bootstrap_ref "${arch_bootstrap_ref}" \
        --arg omarchy_source "${omarchy_source}" \
        --arg omarchy_iso_source "${omarchy_iso_source}" \
        --arg omarchy_version "${omarchy_version}" \
        --arg bootcrew_revision "${bootcrew_revision}" \
        --arg bootc_revision "${bootc_revision}" \
        --arg bootc_version "${bootc_version}" \
        --arg quattro_revision "${quattro_revision}" \
        --arg iso_revision "${iso_revision}" \
        --arg tracking_ref "${tracking_ref}" \
        '{schema:$schema, source_sha:$source_sha, target:$target, image:$image,
          image_id:$image_id, layer_count:($layer_count|tonumber),
          intermediate_archive_exported:false,
          ancestry:{verified:true, parent_target:$parent_target,
            parent_image_id:$parent_image_id, verification_sibling:$verification_sibling},
          created_at:$created_at,
          upstream_pins:{arch_bootstrap_ref:$arch_bootstrap_ref,
            omarchy_source:$omarchy_source, omarchy_iso_source:$omarchy_iso_source,
            omarchy_version:$omarchy_version,
            bootcrew_revision:$bootcrew_revision, bootc_revision:$bootc_revision,
            bootc_version:$bootc_version,
            omarchy_quattro_revision:$quattro_revision,
            omarchy_iso_quattro_revision:$iso_revision,
            tracking_ref:$tracking_ref}}' \
        >"${receipt_path}"
    printf '%s receipt: %s\n' "${target}" "${receipt_path}"
}

build_foundation() {
    local head_sha=""
    local bootcrew_ref="${BOOTCREW_IMAGE_REF:-localhost/omarchy-bootc:bootcrew-system}"
    local image_ref="${FOUNDATION_IMAGE_REF:-localhost/omarchy-bootc:foundation}"
    local bootcrew_image_id=""
    local head_short=""
    local bootcrew_revision=""
    local bootc_revision=""
    local bootc_version=""
    local arch_bootstrap_ref=""

    cd "${ROOT_DIR}"
    head_sha="$(git rev-parse --verify HEAD)"
    head_short="${head_sha:0:12}"
    bootcrew_revision="$(read_pin vendor/bootcrew/REVISION)"
    bootc_revision="$(read_pin vendor/bootcrew/BOOTC_REVISION)"
    bootc_version="$(tr -d '\r\n' <vendor/bootcrew/BOOTC_VERSION)"
    arch_bootstrap_ref="$(read_arg ARCH_BOOTSTRAP_REF)"
    run_logged bootcrew-system-build sudo -n podman build \
        --pull=missing --format=oci --target bootcrew-system \
        --tag "${bootcrew_ref}" \
        --label "org.opencontainers.image.revision=${head_sha}" \
        --label "com.omarchy.bootcrew-system.head=${head_sha}" \
        --label "com.omarchy.foundation.bootcrew=${bootcrew_revision}" \
        --label "com.omarchy.foundation.bootc=${bootc_revision}" \
        --label "com.omarchy.foundation.bootc-version=${bootc_version}" \
        --label "com.omarchy.foundation.arch-bootstrap=${arch_bootstrap_ref}" \
        "${ROOT_DIR}"
    bootcrew_image_id="$(sudo -n podman image inspect "${bootcrew_ref}" --format '{{.Id}}')"
    # foundation is a verification sibling of quattro-assembly branching off bootcrew-system.
    python3 "${ROOT_DIR}/scripts/ci/pin-stage-parent.py" \
        "${ROOT_DIR}/Containerfile" foundation bootcrew-system "${bootcrew_image_id}" \
        "${ARTIFACT_DIR}/Containerfile.foundation.pinned"
    run_logged foundation-verification-sibling-build sudo -n podman build \
        --file "${ARTIFACT_DIR}/Containerfile.foundation.pinned" \
        --pull=missing --format=oci --target foundation \
        --tag "${image_ref}" \
        --label "org.opencontainers.image.revision=${head_sha}" \
        --label "com.omarchy.foundation.role=verification-sibling" \
        --label "com.omarchy.foundation.parent=${bootcrew_image_id}" \
        --label "com.omarchy.foundation.head=${head_sha}" \
        "${ROOT_DIR}"
    run_logged foundation-ancestry verify_stage_ancestry \
        "${bootcrew_image_id}" "${image_ref}" "bootcrew-system -> foundation (verification sibling)"
    run_logged foundation-contract sudo -n podman run --rm --pull=never --privileged \
        "${image_ref}" /usr/lib/omarchy-bootc/foundation-contract.sh
    record_stage_receipt foundation "${image_ref}" omarchy-bootc.foundation-verification-sibling/v1 \
        "omarchy-bootc-foundation-head-${head_sha}-bootc-${bootc_revision:0:12}" \
        "bootcrew-system" "${bootcrew_image_id}" "verification-sibling-of-quattro-assembly"
    printf 'foundation_verification_sibling head=%s bootcrew_system=%s\n' \
        "${head_short}" "${bootcrew_image_id}" | tee "${LOG_DIR}/foundation.txt"
}

build_assembly() {
    local head_sha=""
    local image_ref="${ASSEMBLY_IMAGE_REF:-localhost/omarchy-bootc:assembly}"
    local bootcrew_ref="${BOOTCREW_IMAGE_REF:-localhost/omarchy-bootc:bootcrew-system}"
    local foundation_image_ref="${FOUNDATION_IMAGE_REF:-localhost/omarchy-bootc:foundation}"
    local bootcrew_image_id=""
    local foundation_image_id=""
    local head_short=""

    cd "${ROOT_DIR}"
    head_sha="$(git rev-parse --verify HEAD)"
    head_short="${head_sha:0:12}"
    bootcrew_image_id="$(sudo -n podman image inspect "${bootcrew_ref}" \
        --format '{{.Id}}' 2>/dev/null || true)"
    [[ -n "${bootcrew_image_id}" ]] \
        || die "immutable bootcrew-system parent image is not present before assembly"
    foundation_image_id="$(sudo -n podman image inspect "${foundation_image_ref}" \
        --format '{{.Id}}' 2>/dev/null || true)"
    [[ -n "${foundation_image_id}" ]] \
        || die "foundation verification sibling image is not present before assembly"
    python3 "${ROOT_DIR}/scripts/ci/pin-stage-parent.py" \
        "${ROOT_DIR}/Containerfile" quattro-assembly bootcrew-system "${bootcrew_image_id}" \
        "${ARTIFACT_DIR}/Containerfile.quattro-assembly.pinned"
    run_logged assembly-build sudo -n podman build \
        --file "${ARTIFACT_DIR}/Containerfile.quattro-assembly.pinned" \
        --pull=missing --format=oci --target quattro-assembly \
        --tag "${image_ref}" \
        --label "org.opencontainers.image.revision=${head_sha}" \
        --label "com.omarchy.assembly.head=${head_sha}" \
        --label "com.omarchy.assembly.parent=${bootcrew_image_id}" \
        --label "com.omarchy.assembly.foundation-sibling=${foundation_image_id}" \
        "${ROOT_DIR}"
    run_logged assembly-ancestry verify_stage_ancestry \
        "${bootcrew_image_id}" "${image_ref}" "bootcrew-system -> quattro-assembly"
    run_logged assembly-contract sudo -n podman run --rm --pull=never --privileged \
        "${image_ref}" bash -ceu 'set -euo pipefail
            test -s /usr/share/omarchy-bootc/quattro-package-manifest.txt
            test -s /usr/share/omarchy-bootc/quattro-package-provenance.txt
            test -s /usr/share/omarchy-bootc/package-provenance.txt
            test -s /usr/share/omarchy-bootc/optional-package-resolvability.txt
            test -s /usr/share/omarchy-bootc/pacman.conf
            test -s /usr/share/omarchy-bootc/repository-database-sha256sums.txt
            printf "Omarchy assembly package/provenance contract passed\\n"'
    record_stage_receipt quattro-assembly "${image_ref}" omarchy-bootc.assembly/v1 \
        "omarchy-bootc-assembly-head-${head_sha}" \
        "bootcrew-system" "${bootcrew_image_id}" "${foundation_image_id}"
    printf 'assembly head=%s parent=%s foundation_sibling=%s\n' \
        "${head_short}" "${bootcrew_image_id}" "${foundation_image_id}" | tee "${LOG_DIR}/assembly.txt"
}


build_integration() {
    local head_sha=""
    local image_ref="${INTEGRATION_IMAGE_REF:-localhost/omarchy-bootc:integration}"
    local assembly_image_ref="${ASSEMBLY_IMAGE_REF:-localhost/omarchy-bootc:assembly}"
    local assembly_image_id=""

    cd "${ROOT_DIR}"
    head_sha="$(git rev-parse --verify HEAD)"
    assembly_image_id="$(sudo -n podman image inspect "${assembly_image_ref}" \
        --format '{{.Id}}' 2>/dev/null || true)"
    [[ -n "${assembly_image_id}" ]] \
        || die "immutable assembly image is not present before integration"
    python3 "${ROOT_DIR}/scripts/ci/pin-stage-parent.py" \
        "${ROOT_DIR}/Containerfile" quattro-base quattro-assembly "${assembly_image_id}" \
        "${ARTIFACT_DIR}/Containerfile.quattro-base.pinned"
    run_logged integration-build sudo -n podman build \
        --file "${ARTIFACT_DIR}/Containerfile.quattro-base.pinned" \
        --pull=missing --format=oci --target quattro-integration \
        --tag "${image_ref}" \
        --label "org.opencontainers.image.revision=${head_sha}" \
        --label "com.omarchy.integration.head=${head_sha}" \
        --label "com.omarchy.integration.assembly=${assembly_image_id}" \
        "${ROOT_DIR}"
    run_logged integration-ancestry verify_stage_ancestry \
        "${assembly_image_id}" "${image_ref}" "quattro-assembly -> quattro-integration"
    run_logged integration-lint sudo -n podman run --rm --pull=never --privileged \
        "${image_ref}" bootc container lint --fatal-warnings
    record_stage_receipt quattro-integration "${image_ref}" omarchy-bootc.integration/v1 \
        "omarchy-bootc-integration-head-${head_sha}" \
        "quattro-assembly" "${assembly_image_id}" ""
}
build_candidate() {
    local head_sha=""
    local head_short=""
    local quattro_revision=""
    local iso_revision=""
    local bootcrew_revision=""
    local bootc_revision=""
    local bootc_version=""
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
    bootc_version="$(tr -d '\r\n' <vendor/bootcrew/BOOTC_VERSION)"
    arch_bootstrap_ref="$(read_arg ARCH_BOOTSTRAP_REF)"
    bootcrew_source="$(tr -d '\r\n' <vendor/bootcrew/SOURCE)"
    bootc_source="$(tr -d '\r\n' <vendor/bootcrew/BOOTC_SOURCE)"
    omarchy_source="$(tr -d '\r\n' <sources/omarchy-quattro.source)"
    omarchy_iso_source="$(tr -d '\r\n' <sources/omarchy-iso-quattro.source)"
    omarchy_version="$(tr -d '\r\n' <sources/omarchy-quattro-version)"
    [[ "${bootc_version}" == "v1.16.13" ]] || die "unexpected bootc version record: ${bootc_version}"
    [[ -n "${arch_bootstrap_ref}" && -n "${bootcrew_source}" && -n "${bootc_source}" && -n "${omarchy_source}" && -n "${omarchy_iso_source}" && -n "${omarchy_version}" ]] || die "missing Containerfile or upstream source metadata"

    local integration_image_ref="${INTEGRATION_IMAGE_REF:-localhost/omarchy-bootc:integration}"
    local integration_image_id="" candidate_file="${ROOT_DIR}/Containerfile"
    integration_image_id="$(sudo -n podman image inspect "${integration_image_ref}" --format '{{.Id}}' 2>/dev/null || true)"
    if [[ -n "$integration_image_id" ]]; then
        candidate_file="${ARTIFACT_DIR}/Containerfile.final.pinned"
        python3 "${ROOT_DIR}/scripts/ci/pin-stage-parent.py" \
            "${ROOT_DIR}/Containerfile" final quattro-integration "$integration_image_id" "$candidate_file"
    fi
    run_logged build sudo -n podman build \
        --file "$candidate_file" \
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
        --label "com.omarchy.candidate.bootc-version=${bootc_version}" \
        "${ROOT_DIR}"

    run_logged fatal-lint sudo -n podman run --rm --pull=never --privileged "${IMAGE_REF}" bootc container lint --fatal-warnings
    if [[ -n "$integration_image_id" ]]; then
        run_logged final-ancestry verify_stage_ancestry \
            "${integration_image_id}" "${IMAGE_REF}" "quattro-integration -> final"
    fi
    run_logged candidate-dependencies sudo -n podman run --rm --pull=never \
        "${IMAGE_REF}" /usr/lib/omarchy-bootc/acceptance-dependencies.sh final

    image_id="$(sudo -n podman image inspect "${IMAGE_REF}" --format '{{.Id}}')"
    [[ "${image_id}" =~ ^(sha256:)?[[:xdigit:]]{64}$ ]] || die "image ID is not immutable: ${image_id}"

    local export_free_kib=""
    export_free_kib="$(df -Pk "${ARTIFACT_DIR}" | awk 'NR == 2 {print $4}')"
    ((export_free_kib >= MIN_FREE_GIB * 1024 * 1024)) \
        || die "export store has only $((export_free_kib / 1024 / 1024)) GiB free before final archive export"

    candidate_stem="omarchy-bootc-candidate-head-${head_sha}-quattro-${quattro_revision:0:12}-iso-${iso_revision:0:12}-bootcrew-${bootcrew_revision:0:12}-bootc-${bootc_revision:0:12}"
    archive_path="${ARTIFACT_DIR}/${candidate_stem}.oci.tar"
    receipt_path="${ARTIFACT_DIR}/${candidate_stem}.receipt.json"
    run_logged export export_archive "${archive_path}" "${IMAGE_REF}"
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
        --arg bootc_version "${bootc_version}" \
        --arg quattro_revision "${quattro_revision}" \
        --arg iso_revision "${iso_revision}" \
        --arg omarchy_version "${omarchy_version}" \
        --arg tracking_ref "${tracking_ref}" \
        --arg firmware_source "$(cat sources/apple-bcm-firmware.source)" \
        --arg firmware_sha256 "$(awk 'NR == 1 {print $1}' sources/apple-bcm-firmware.sha256)" \
        --arg lint_result 'passed:bootc container lint --fatal-warnings' \
        '{schema:$schema, repository:$repository, event:$event,
          source_sha:$head, source_head:$head,
          image:$image, archive:$archive, archive_sha256:$archive_sha256,
          archive_size_bytes:($archive_size|tonumber),
          oci_manifest_digest:$manifest_digest, manifest_digest:$manifest_digest,
          image_id:$image_id, created_at:$created_at, lint_result:$lint_result,
          upstream_pins:{arch_bootstrap_ref:$arch_bootstrap_ref,
            omarchy_source:$omarchy_source, omarchy_iso_source:$omarchy_iso_source,
            bootcrew_source:$bootcrew_source, bootcrew_revision:$bootcrew_revision,
            bootc_source:$bootc_source, bootc_revision:$bootc_revision,
            bootc_version:$bootc_version,
            omarchy_quattro_revision:$quattro_revision,
            omarchy_iso_quattro_revision:$iso_revision,
            omarchy_version:$omarchy_version, tracking_ref:$tracking_ref,
            apple_bcm_firmware:{source:$firmware_source, sha256:$firmware_sha256}},
          acceptance_overlay:{applied:false, target:"final"}}' \
        >"${receipt_path}"

    # Verify archive identity and scan EVERY exported layer for pacman secret material.
    run_logged archive-layer-scan python3 "${ROOT_DIR}/scripts/ci/verify-candidate-archive.py" \
        "${receipt_path}" "${archive_path}" "${head_sha}"

    printf 'Candidate archive: %s\nReceipt: %s\n' "${archive_path}" "${receipt_path}"
}

case "${1:-}" in
    preflight)
        preflight
        ;;
    packages)
        printf 'source_head=%s\n' "$(git -C "${ROOT_DIR}" rev-parse HEAD)" \
            >"${LOG_DIR}/package-subject.txt"
        run_logged package-preflight sudo -n podman run --rm --pull=missing \
            -v "${ROOT_DIR}/build:/ctx/build:ro" \
            -v "${ROOT_DIR}/custom/pacman:/ctx/custom/pacman:ro" \
            -v "${ROOT_DIR}/sources:/ctx/sources:ro" \
            -v "${ROOT_DIR}/scripts/ci/check-published-packages.sh:/ctx/check.sh:ro" \
            "$(read_arg ARCH_BOOTSTRAP_REF)" bash /ctx/check.sh
        ;;
    foundation)
        build_foundation
        ;;
    assembly)
        build_assembly
        ;;
    integration)
        build_integration
        ;;
    build)
        build_candidate
        ;;
    *)
        echo "Usage: $0 {preflight|packages|foundation|assembly|integration|build}" >&2
        exit 2
        ;;
esac
