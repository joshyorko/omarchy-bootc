#!/usr/bin/env bash
set -euo pipefail
repository=${1:?Repository}; digest=${2:?Accepted signed digest}; tracking=${3:?Intended tracking channel}
[[ $repository == ghcr.io/joshyorko/omarchy-bootc && $digest =~ ^sha256:[0-9a-f]{64}$ ]]
[[ $tracking == testing || $tracking == stable ]]
: "${SOURCE_SHA:?Expected attested source}"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bash "$script_dir/verify-published-image-trust.sh" "$repository@$digest" "$SOURCE_SHA"
authfile=${REGISTRY_AUTH_FILE:-${DOCKER_CONFIG:-$HOME/.docker}/config.json}
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/omarchy-channel.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
copy_tag() {
    local tag=$1 actual
    [[ $tag =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]
    skopeo copy --authfile "$authfile" --preserve-digests "docker://$repository@$digest" "docker://$repository:$tag"
    skopeo inspect --authfile "$authfile" --raw "docker://$repository:$tag" >"$scratch/manifest.json"
    actual="sha256:$(sha256sum "$scratch/manifest.json" | cut -d' ' -f1)"
    [[ $actual == "$digest" ]]
}
read -r -a tags <<<"${METADATA_TAGS:-}"
for tag in "${tags[@]}"; do
    [[ $tag == "$tracking" ]] || copy_tag "$tag"
done
# The intended moving stream is updated only after signature/attestation and
# all non-stream tags have passed exact raw-manifest verification.
copy_tag "$tracking"
