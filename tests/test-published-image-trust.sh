#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${root_dir}/.github/workflows/build.yml"
verifier="${root_dir}/scripts/ci/verify-published-image-trust.sh"
repositories="${root_dir}/custom/pacman/quattro-repositories.conf"

grep -Fq 'https://github.com/joshyorko/omarchy-bootc/.github/workflows/build.yml@refs/heads/main' "${verifier}"
grep -Fq 'https://token.actions.githubusercontent.com' "${verifier}"
grep -Fq 'cosign sign --yes' "${workflow}"
grep -Fq 'cosign attest --yes' "${workflow}"
# The workflow expression is asserted literally.
# shellcheck disable=SC2016
grep -Fq 'acceptance_overlay:"not-applied"' "${workflow}" ||
    grep -Fq 'acceptance_overlay:$acceptance_overlay' "${workflow}"
if grep -Eiq 'SigLevel[[:space:]]*=[[:space:]]*(Optional|Never)|TrustAll' "${repositories}"; then
    printf 'Omarchy repository signature verification is not fail-closed\n' >&2
    exit 1
fi

stub_dir="$(mktemp -d)"
trap 'rm -rf "${stub_dir}"' EXIT
cat >"${stub_dir}/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${COSIGN_CALLS}"
if [[ "$1" == verify-attestation ]]; then
    predicate="$(jq -cn \
        --arg image "${TRUST_IMAGE}" \
        --arg digest "${TRUST_DIGEST}" \
        --arg source_sha "${TRUST_PAYLOAD_SOURCE_SHA}" \
        '{schema:"omarchy-bootc.published-image/v1", image:$image,
          oci_manifest_digest:$digest, source_sha:$source_sha,
          acceptance_overlay:"not-applied"}')"
    statement="$(jq -cn --argjson predicate "${predicate}" '{predicate:$predicate}')"
    payload="$(printf '%s' "${statement}" | base64 -w0)"
    printf '[{"payload":"%s"}]\n' "${payload}"
fi
EOF
chmod +x "${stub_dir}/cosign"
export COSIGN_CALLS="${stub_dir}/calls"
export PATH="${stub_dir}:${PATH}"
test_image=ghcr.io/example/image
test_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
test_source_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export TRUST_IMAGE="${test_image}"
export TRUST_DIGEST="${test_digest}"
export TRUST_PAYLOAD_SOURCE_SHA="${test_source_sha}"
if "${verifier}" "${test_image}:stable" "${test_source_sha}" >/dev/null 2>&1; then
    printf 'trust verifier accepted a mutable image tag\n' >&2
    exit 1
fi
[[ ! -e "${COSIGN_CALLS}" ]]
"${verifier}" "${test_image}@${test_digest}" "${test_source_sha}" >/dev/null
if "${verifier}" "${test_image}@${test_digest}" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1; then
    printf 'trust verifier accepted an image without the required attestation predicate\n' >&2
    exit 1
fi
grep -Fq -- '--certificate-identity https://github.com/joshyorko/omarchy-bootc/.github/workflows/build.yml@refs/heads/main' "${COSIGN_CALLS}"
grep -Fq -- '--certificate-oidc-issuer https://token.actions.githubusercontent.com' "${COSIGN_CALLS}"
