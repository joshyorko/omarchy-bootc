#!/usr/bin/env bash
set -euo pipefail

# Consume the exported final image, never rebuild its source graph.
candidate_dir="${1:?Usage: candidate-runtime.sh <downloaded-artifact-directory>}"
artifact_dir="${CI_ARTIFACT_DIR:?Set CI_ARTIFACT_DIR for runtime receipts}"
mkdir -p "${artifact_dir}"
shopt -s nullglob
receipts=("${candidate_dir}"/*.receipt.json)
[[ ${#receipts[@]} == 1 ]]
receipt="${receipts[0]}"
head="$(git rev-parse HEAD)"
jq -e --arg head "${head}" '.source_head == $head' "${receipt}" >/dev/null
archive_name="$(jq -er .archive "${receipt}")"
[[ "${archive_name}" == "$(basename "${archive_name}")" ]]
archive="${candidate_dir}/${archive_name}"
checksum="$(jq -er .archive_sha256 "${receipt}")"
[[ "sha256:$(sha256sum "${archive}" | cut -d' ' -f1)" == "${checksum}" ]]
manifest="$(tar -xOf "${archive}" index.json | jq -er '.manifests[0].digest')"
[[ "${manifest}" == "$(jq -er .manifest_digest "${receipt}")" ]]
cp "${receipt}" "${artifact_dir}/parent-candidate.receipt.json"
sudo -n podman load -i "${archive}"
parent="$(jq -er .image_id "${receipt}")"
[[ "$(sudo -n podman inspect --type image "${parent}" --format '{{.Id}}')" == "${parent}" ]]

overlay=localhost/omarchy-bootc:acceptance
sudo -n podman build --pull=never --format=oci \
    --build-arg "CANDIDATE_IMAGE=${parent}" \
    --label "com.omarchy.candidate.head=${head}" \
    --label "com.omarchy.acceptance.parent=${manifest}" \
    -f scripts/ci/acceptance-overlay.Containerfile -t "${overlay}" . \
    2>&1 | tee "${artifact_dir}/acceptance-overlay-build.log"
sudo -n podman run --rm --pull=never --privileged "${overlay}" \
    bootc container lint --fatal-warnings \
    2>&1 | tee "${artifact_dir}/acceptance-overlay-lint.log"
sudo -n podman image inspect "${overlay}" | tee "${artifact_dir}/acceptance-overlay-inspect.json" >/dev/null
overlay_id="$(sudo -n podman inspect --type image "${overlay}" --format '{{.Id}}')"

# Fetch only the official acceptance machinery at the accepted source pin.
upstream_tests="$(mktemp -d)"
git -C "${upstream_tests}" init -q
git -C "${upstream_tests}" remote add origin "$(cat sources/omarchy-quattro.source)"
quattro_revision="$(cat sources/omarchy-quattro.revision)"
git -C "${upstream_tests}" fetch --depth=1 --filter=blob:none origin "${quattro_revision}"
[[ "$(git -C "${upstream_tests}" rev-parse FETCH_HEAD)" == "${quattro_revision}" ]]
git -C "${upstream_tests}" archive FETCH_HEAD test/acceptance test/acceptance.d \
    | tar -x -C "${upstream_tests}"
printf '%s\n' "${quattro_revision}" >"${artifact_dir}/upstream-acceptance-revision.txt"

sudo -n env CI_ARTIFACT_DIR="${artifact_dir}" \
    UPSTREAM_ACCEPTANCE_DIR="${upstream_tests}" \
    NATIVE_ACCEPTANCE_SCRIPT="${PWD}/scripts/ci/guest-native-acceptance.sh" \
    timeout --signal=TERM --kill-after=30s 45m \
    bash scripts/ci/vm-smoke.sh "${overlay}" \
    2>&1 | tee "${artifact_dir}/vm-smoke.log"

# This success receipt is emitted only after the exact image passed the VM and
# pinned upstream/native acceptance suites. Its accepted subject remains the
# final candidate image; the disposable acceptance overlay has its own ID.
jq -n \
    --arg source_sha "${head}" \
    --arg image_archive "${archive_name}" \
    --arg archive_sha256 "${checksum}" \
    --arg candidate_oci_manifest_digest "${manifest}" \
    --arg candidate_local_image_id "${parent}" \
    --arg acceptance_overlay_image_id "${overlay_id}" \
    --arg upstream_acceptance_revision "${quattro_revision}" \
    '{schema:"omarchy-bootc.accepted-candidate/v1",
      source_sha:$source_sha,
      candidate:{archive:$image_archive, archive_sha256:$archive_sha256,
        oci_manifest_digest:$candidate_oci_manifest_digest,
        local_image_id:$candidate_local_image_id},
      acceptance:{status:"passed", upstream_revision:$upstream_acceptance_revision,
        overlay_image_id:$acceptance_overlay_image_id,
        overlay_scope:"disposable-test-fixture-only"},
      publishable:false}' \
    >"${artifact_dir}/accepted-candidate.receipt.json"
