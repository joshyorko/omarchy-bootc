#!/usr/bin/env bash
# Trusted publisher only: copy the accepted OCI manifest without conversion.
set -euo pipefail
candidate=${1:?Candidate artifact directory}
accepted=${2:?Accepted-candidate receipt}
repository=${3:?Registry repository}
source_head=${4:?Accepted source SHA}
tag=${5:?Unique non-channel promotion tag}
[[ $repository == ghcr.io/joshyorko/omarchy-bootc ]]
[[ $source_head =~ ^[0-9a-f]{40}$ && $tag =~ ^accepted-${source_head}-[0-9]+-[0-9]+$ ]]
receipt="$candidate/candidate.receipt.json"
archive="$candidate/$(jq -er .archive "$receipt")"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/omarchy-promote.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 "$script_dir/verify-candidate-archive.py" "$receipt" "$archive" "$source_head" >"$scratch/archive.json"
digest=$(jq -er .manifest_digest "$scratch/archive.json")
checksum=$(jq -er .archive_sha256 "$scratch/archive.json")
image_id=$(jq -er .image_id "$scratch/archive.json")
jq -e --arg source "$source_head" --arg digest "$digest" --arg checksum "$checksum" --arg image_id "$image_id" '
  .source_sha == $source and .acceptance.status == "passed" and
  .acceptance.overlay_scope == "disposable-test-fixture-only" and
  .candidate.oci_manifest_digest == $digest and
  .candidate.archive_sha256 == $checksum and .candidate.local_image_id == $image_id
' "$accepted" >/dev/null
authfile=${REGISTRY_AUTH_FILE:-${DOCKER_CONFIG:-$HOME/.docker}/config.json}
skopeo copy --authfile "$authfile" --preserve-digests \
    "oci-archive:$archive" "docker://$repository:$tag" >&2
skopeo inspect --authfile "$authfile" --raw "docker://$repository:$tag" >"$scratch/remote-manifest.json"
actual="sha256:$(sha256sum "$scratch/remote-manifest.json" | cut -d' ' -f1)"
[[ $actual == "$digest" ]] || { echo 'Remote manifest differs from accepted OCI bytes; refusing signing/channel update' >&2; exit 1; }
if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'digest=%s\n' "$digest" >>"$GITHUB_OUTPUT"; fi
printf '%s\n' "$digest"
