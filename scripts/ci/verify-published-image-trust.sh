#!/usr/bin/env bash
set -euo pipefail

readonly certificate_identity='https://github.com/joshyorko/omarchy-bootc/.github/workflows/build.yml@refs/heads/main'
readonly oidc_issuer='https://token.actions.githubusercontent.com'
readonly attestation_type='https://omarchy.org/attestation/published-image-receipt/v1'

if (($# != 2)); then
    printf 'usage: verify-published-image-trust.sh IMAGE@sha256:DIGEST SOURCE_SHA\n' >&2
    exit 2
fi
image_ref="$1"
expected_source_sha="$2"
[[ "${image_ref}" =~ @sha256:[[:xdigit:]]{64}$ ]] || {
    printf 'Refusing mutable or malformed image reference: %s\n' "${image_ref}" >&2
    exit 2
}
[[ "${expected_source_sha}" =~ ^[[:xdigit:]]{40}$ ]] || {
    printf 'Refusing malformed source SHA: %s\n' "${expected_source_sha}" >&2
    exit 2
}
expected_image="${image_ref%@*}"
expected_digest="${image_ref##*@}"
command -v cosign >/dev/null 2>&1 || {
    printf 'cosign is required to verify the published image\n' >&2
    exit 127
}
command -v jq >/dev/null 2>&1 || {
    printf 'jq is required to validate the signed image receipt\n' >&2
    exit 127
}

cosign verify \
    --certificate-identity "${certificate_identity}" \
    --certificate-oidc-issuer "${oidc_issuer}" \
    "${image_ref}" >/dev/null

cosign verify-attestation \
    --output json \
    --type "${attestation_type}" \
    --certificate-identity "${certificate_identity}" \
    --certificate-oidc-issuer "${oidc_issuer}" \
    "${image_ref}" |
    jq -e --arg image "${expected_image}" \
        --arg digest "${expected_digest}" \
        --arg source_sha "${expected_source_sha}" '
      any(.[].payload | @base64d | fromjson | .predicate;
        .schema == "omarchy-bootc.published-image/v1" and
        .image == $image and
        .source_sha == $source_sha and
        .oci_manifest_digest == $digest and
        .acceptance_overlay == "not-applied")
    ' >/dev/null
