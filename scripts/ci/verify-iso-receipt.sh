#!/usr/bin/env bash
# The caller must first verify Actions producer metadata and signed image trust.
set -euo pipefail
directory=${1:?ISO artifact directory}
builder=${2:?Verified producer head SHA}
source_sha=${3:?Attested payload source SHA}
image_ref=${4:?Signed immutable image reference}
run=${5:?Verified producer run ID}
[[ $builder =~ ^[a-f0-9]{40}$ && $source_sha =~ ^[a-f0-9]{40}$ && $run =~ ^[0-9]+$ ]]
[[ $image_ref =~ ^ghcr\.io/joshyorko/omarchy-bootc@sha256:[a-f0-9]{64}$ ]]
receipt="$directory/iso.receipt.json"
jq -e --arg builder "$builder" --arg source "$source_sha" --arg image "$image_ref" --arg run "$run" '
    .schema == "omarchy-bootc.installer-iso/v1" and
    .builder_source_sha == $builder and .install_source_sha == $source and
    .install_image_ref == $image and .run_id == $run and
    .tracking_image_ref == "ghcr.io/joshyorko/omarchy-bootc:testing" and
    (.iso_sha256 | test("^[a-f0-9]{64}$")) and
    (.iso_filename | test("^[A-Za-z0-9._-]+\\.iso$"))
' "$receipt" >/dev/null
file=$(jq -er .iso_filename "$receipt")
[[ -f $directory/$file && ! -L $directory/$file ]]
actual=$(sha256sum -- "$directory/$file" | cut -d ' ' -f1)
[[ $actual == "$(jq -er .iso_sha256 "$receipt")" ]]
printf 'Verified ISO bytes, signed payload identity and Actions producer binding\n'
