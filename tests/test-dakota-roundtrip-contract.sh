#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/ci/dakota-roundtrip.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/dakota-roundtrip.yml"
RECEIPT_HELPER="${ROOT_DIR}/scripts/ci/lib/dakota-receipt.sh"
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' EXIT
valid_quattro_ref="ghcr.io/joshyorko/omarchy-bootc@sha256:$(printf 'b%.0s' {1..64})"
expect_refusal() {
    local expected="$1" output="$tmp/output"
    shift
    if env \
        CI_ARTIFACT_DIR="$tmp/artifacts" \
        QUATTRO_SOURCE_SHA="$(printf 'a%.0s' {1..40})" \
        QUATTRO_IMAGE_REF="$valid_quattro_ref" \
        DAKOTA_TRACKING_REF='ghcr.io/projectbluefin/dakota:stable' \
        QUATTRO_TRACKING_REF='ghcr.io/joshyorko/omarchy-bootc:testing' \
        "$@" bash "$SCRIPT" >"$output" 2>&1; then
        fail "invalid Dakota fixture was accepted: $*"
    fi
    grep -Fq "$expected" "$output" ||
        fail "invalid Dakota fixture reported the wrong error: $*"
}
expect_refusal 'Dakota input is not immutable' \
    DAKOTA_IMAGE_REF='ghcr.io/projectbluefin/dakota:stable'
expect_refusal 'Dakota tracking ref is not mutable' \
    DAKOTA_TRACKING_REF='ghcr.io/projectbluefin/dakota:stable;touch'
expect_refusal 'Quattro input is not immutable' \
    QUATTRO_IMAGE_REF='ghcr.io/joshyorko/omarchy-bootc:testing'
expect_refusal 'Dakota image ref does not match the repository-owned current release' \
    DAKOTA_IMAGE_REF='ghcr.io/example/dakota@sha256:ddab2e2d816976a8f181603987e76d1c992109f435b2abdf1eae76f40f7139f8'



[[ -x "${SCRIPT}" ]] || fail 'Dakota round-trip runner is missing or not executable'
[[ -f "${WORKFLOW}" ]] || fail 'Dakota round-trip workflow is missing'
[[ -x "${RECEIPT_HELPER}" ]] || fail 'Gate 4 receipt helper is missing or not executable'
grep -Fq 'source "${ROOT_DIR}/scripts/ci/lib/dakota-receipt.sh"' "${SCRIPT}" ||
    fail 'Gate 4 runner does not load its receipt helper'
# Execute receipt construction and validate the consumer-visible identity fields.
# shellcheck disable=SC1090
source "${RECEIPT_HELPER}"
receipt="${tmp}/gate4-receipt.json"
write_gate4_receipt "$receipt" \
    'ghcr.io/projectbluefin/dakota@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'ghcr.io/projectbluefin/dakota:stable' \
    'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    "$valid_quattro_ref" 'ghcr.io/joshyorko/omarchy-bootc:testing' \
    'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    "$(printf 'c%.0s' {1..40})" composefs btrfs composefs
jq -e '
    .schema == "omarchy-bootc.gate4-dakota-roundtrip/v1" and
    .gate == 4 and .result == "passed" and .runtime_proven == true and
    .source.acceptance_overlay_digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
    .forward.adoption == "complete" and .reverse.user_home_preserved == true
' "$receipt" >/dev/null || fail 'Gate 4 receipt fields are incorrect'


# Keep the current disposable Dakota input immutable and repository-owned.
grep -Fq 'ghcr.io/projectbluefin/dakota@sha256:ddab2e2d816976a8f181603987e76d1c992109f435b2abdf1eae76f40f7139f8' "${SCRIPT}" ||
    fail 'Gate 4 does not freeze the reviewed current Dakota digest'
grep -Fq 'DAKOTA_EXPECTED_DIGEST="sha256:ddab2e2d816976a8f181603987e76d1c992109f435b2abdf1eae76f40f7139f8"' "${SCRIPT}" ||
    fail 'Gate 4 expected Dakota digest is not fixed'
grep -Fq 'A-Za-z0-9._-' "${SCRIPT}" ||
    fail 'Gate 4 tracking refs do not reject shell metacharacters'

assert_order() {
    local label="$1" previous=0 needle line
    shift
    for needle in "$@"; do
        line="$(grep -nF -- "$needle" "${SCRIPT}" | head -n1 | cut -d: -f1)" ||
            fail "${label} is missing: ${needle}"
        (( line > previous )) ||
            fail "${label} is out of order at: ${needle}"
        previous="${line}"
    done
}
# The disposable overlay context is removed before each run and must be
# recreated before its Containerfile is written.
assert_order 'Dakota overlay context' \
    'rm -rf "${DAKOTA_OVERLAY_OCI}" "${OVERLAY_CONTEXT}" "${RAW_PATH}" "${QCOW_PATH}"' \
    'mkdir -p "${OVERLAY_CONTEXT}"' \
    'cat >"${OVERLAY_CONTEXT}/Containerfile"'
grep -Fq 'source_configured_ref}" == "${DAKOTA_IMAGE_REF}"' "${SCRIPT}" ||
    fail 'Gate 4 does not bind live Dakota configuration to the frozen source ref'
grep -Fq 'assert_status_digest "${ARTIFACT_DIR}/dakota-source-status.json" "${DAKOTA_EXPECTED_DIGEST}"' "${SCRIPT}" ||
    fail 'Gate 4 does not verify the booted Dakota source digest'
assert_order 'Dakota install target syntax' \
    '--composefs-backend --via-loopback \' \
    '--bootloader systemd \' \
    '/data/gate4/dakota-roundtrip.raw \'




# Gate 4 is a real forward/reverse boot operation, not merely an input and
# publication contract. Keep the immutable source, exact staged/booted
# digests, preserved user state, and receipt assertions visible in sequence.
assert_order 'Dakota forward round-trip' \
    'source_transition_env=(' \
    'transition.sh inspect-source' \
    'transition.sh preflight' \
    'transition.sh capture-state' \
    'transition.sh backup' \
    'transition.sh apply --confirm' \
    'quattro-staged-status.json' \
    'reboot_guest || fail' \
    'quattro-booted-status.json' \
    'assert_status_digest "${ARTIFACT_DIR}/quattro-booted-status.json"' \
    'quattro-user-state.txt'
assert_order 'Dakota reverse round-trip' \
    'reverse_env=(' \
    '${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh inspect-source' \
    '${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh preflight' \
    '${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh capture-state' \
    '${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh backup' \
    '${reverse_env[*]} /home/omarchy/transition/omarchy-transition.sh apply --confirm' \
    'dakota-reverse-staged-status.json' \
    'dakota-reverse-status.json' \
    'assert_status_digest "${ARTIFACT_DIR}/dakota-reverse-status.json"' \
    'dakota-reverse-user-state.txt'
grep -Fq 'result:"passed"' "${RECEIPT_HELPER}" ||
    fail 'Gate 4 receipt does not record a passed result'
grep -Fq 'source:{immutable_ref:$dakota_ref' "${RECEIPT_HELPER}" ||
    fail 'Gate 4 receipt omits the immutable source identity'
grep -Fq 'forward:{accepted_ref:$quattro_ref' "${RECEIPT_HELPER}" ||
    fail 'Gate 4 receipt omits the forward candidate identity'
grep -Fq 'reverse:{tracking_ref:$dakota_tracking_ref' "${RECEIPT_HELPER}" ||
    fail 'Gate 4 receipt omits the reverse identity'
grep -Fq 'user_home_preserved:true' "${RECEIPT_HELPER}" ||
    fail 'Gate 4 receipt omits user-state preservation'


grep -Fq 'workflow_dispatch:' "${WORKFLOW}" || fail 'Gate 4 workflow is not manually dispatchable'
grep -Fq 'verify-published-image-trust.sh' "${WORKFLOW}" || fail 'Gate 4 workflow does not verify the accepted Quattro artifact'
grep -Fq 'dakota-roundtrip.sh' "${WORKFLOW}" || fail 'Gate 4 workflow does not execute the round-trip runner'
grep -Fq 'actions/upload-artifact@v4' "${WORKFLOW}" || fail 'Gate 4 workflow does not retain receipts'
if grep -Eq 'omarchy-bootc:stable|DEFAULT_TAG: stable' "${WORKFLOW}" "${SCRIPT}"; then
    fail 'Gate 4 must not introduce an Omarchy :stable publication or input'
fi

printf 'PASS: Dakota round-trip contract\n'
