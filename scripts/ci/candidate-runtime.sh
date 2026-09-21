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
jq -n --arg head "${head}" --arg parent "${manifest}" \
    --arg overlay "$(sudo -n podman inspect --type image "${overlay}" --format '{{.Id}}')" \
    '{source_head:$head, parent_manifest_digest:$parent, acceptance_image_id:$overlay,
      scope:"Disposable acceptance child; not the publishable final digest"}' \
    >"${artifact_dir}/runtime-subject.json"

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
