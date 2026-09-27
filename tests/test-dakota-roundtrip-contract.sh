#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/ci/dakota-roundtrip.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/dakota-roundtrip.yml"
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "${SCRIPT}" ]] || fail 'Dakota round-trip runner is missing or not executable'
[[ -f "${WORKFLOW}" ]] || fail 'Dakota round-trip workflow is missing'

# Keep the current disposable Dakota input immutable and repository-owned.
grep -Fq 'ghcr.io/projectbluefin/dakota@sha256:ddab2e2d816976a8f181603987e76d1c992109f435b2abdf1eae76f40f7139f8' "${SCRIPT}" ||
    fail 'Gate 4 does not freeze the reviewed current Dakota digest'
grep -Fq 'DAKOTA_EXPECTED_DIGEST="sha256:ddab2e2d816976a8f181603987e76d1c992109f435b2abdf1eae76f40f7139f8"' "${SCRIPT}" ||
    fail 'Gate 4 expected Dakota digest is not fixed'

# A green receipt can only be emitted after live status and both direction
# transitions pass. These strings are deliberately executable contract checks.
for required in \
    'bootc status --format=json' \
    '.status.booted.image.store' \
    'preflight' \
    'capture-state' \
    'backup' \
    'apply --confirm' \
    'dakota-forward' \
    'quattro-reverse' \
    'adoption-recovery-contract.log' \
    'gate4-dakota-roundtrip.receipt.json' \
    'hardware_scope:"x86_64 UEFI QEMU; no physical hardware claim"'; do
    grep -Fq -- "${required}" "${SCRIPT}" || fail "Gate 4 runner is missing ${required}"
done

grep -Fq 'workflow_dispatch:' "${WORKFLOW}" || fail 'Gate 4 workflow is not manually dispatchable'
grep -Fq 'verify-published-image-trust.sh' "${WORKFLOW}" || fail 'Gate 4 workflow does not verify the accepted Quattro artifact'
grep -Fq 'dakota-roundtrip.sh' "${WORKFLOW}" || fail 'Gate 4 workflow does not execute the round-trip runner'
grep -Fq 'actions/upload-artifact@v4' "${WORKFLOW}" || fail 'Gate 4 workflow does not retain receipts'
if grep -Eq 'omarchy-bootc:stable|DEFAULT_TAG: stable' "${WORKFLOW}" "${SCRIPT}"; then
    fail 'Gate 4 must not introduce an Omarchy :stable publication or input'
fi

printf 'PASS: Dakota round-trip contract\n'
