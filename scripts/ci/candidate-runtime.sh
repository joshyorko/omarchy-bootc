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
sudo -n podman run --rm --pull=never "${parent}" \
    /usr/lib/omarchy-bootc/acceptance-dependencies.sh final \
    2>&1 | tee "${artifact_dir}/candidate-dependencies.log"

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
sudo -n podman run --rm --pull=never "${overlay}" \
    /usr/lib/omarchy-bootc/acceptance-dependencies.sh overlay \
    2>&1 | tee "${artifact_dir}/overlay-dependencies.log"
sudo -n podman image inspect "${overlay}" | tee "${artifact_dir}/acceptance-overlay-inspect.json" >/dev/null
overlay_id="$(sudo -n podman inspect --type image "${overlay}" --format '{{.Id}}')"

# Fetch only the official acceptance machinery at the accepted source pin.
upstream_tests="$(mktemp -d)"
trap 'rm -rf -- "${upstream_tests}"' EXIT
git -C "${upstream_tests}" init -q
git -C "${upstream_tests}" remote add origin "$(cat sources/omarchy-quattro.source)"
quattro_revision="$(cat sources/omarchy-quattro.revision)"
git -C "${upstream_tests}" fetch --depth=1 --filter=blob:none origin "${quattro_revision}"
[[ "$(git -C "${upstream_tests}" rev-parse FETCH_HEAD)" == "${quattro_revision}" ]]
# Both the pinned upstream suite and its bounded bootc adaptation are mandatory.
git -C "${upstream_tests}" archive FETCH_HEAD test/acceptance test/acceptance.d \
    | tar -x -C "${upstream_tests}"
python3 scripts/ci/adapt-upstream-acceptance.py \
    --upstream-root "${upstream_tests}" --revision "${quattro_revision}" \
    --artifacts "${artifact_dir}"
printf '%s\n' "${quattro_revision}" >"${artifact_dir}/upstream-acceptance-revision.txt"

vm_env=(
  "CI_ARTIFACT_DIR=${artifact_dir}"
  "VM_PODMAN_ROOTFUL=1"
  "NATIVE_ACCEPTANCE_SCRIPT=${PWD}/scripts/ci/guest-native-acceptance.sh"
  "UPSTREAM_ACCEPTANCE_DIR=${upstream_tests}"
)
env "${vm_env[@]}" \
    timeout --signal=TERM --kill-after=30s 90m \
    bash scripts/ci/vm-smoke.sh "${overlay}" \
    2>&1 | tee "${artifact_dir}/vm-smoke.log"

# Success proves every retained upstream/native gate plus the two explicitly
# adapted bootc filesystem/kernel invariants. The adaptation receipt is part
# of this evidence; the disposable overlay is not the publishable image.
jq -n \
    --arg source_sha "${head}" \
    --arg image_archive "${archive_name}" \
    --arg archive_sha256 "${checksum}" \
    --arg candidate_oci_manifest_digest "${manifest}" \
    --arg candidate_local_image_id "${parent}" \
    --arg acceptance_overlay_image_id "${overlay_id}" \
    --arg upstream_acceptance_revision "${quattro_revision}" \
    --slurpfile adaptation "${artifact_dir}/upstream-acceptance-adaptation.json" \
    '{schema:"omarchy-bootc.accepted-candidate/v1",
      source_sha:$source_sha,
      candidate:{archive:$image_archive, archive_sha256:$archive_sha256,
        oci_manifest_digest:$candidate_oci_manifest_digest,
        local_image_id:$candidate_local_image_id},
      acceptance:{status:"passed", upstream_revision:$upstream_acceptance_revision,
        upstream_suite:"passed-with-bootc-filesystem-kernel-adapter",
        upstream_adaptation:$adaptation[0],
        overlay_image_id:$acceptance_overlay_image_id,
        overlay_scope:"disposable-test-fixture-only"},
      publishable:false}' \
    >"${artifact_dir}/accepted-candidate.receipt.json"
