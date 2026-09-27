#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/ci/vm-smoke.sh"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[[ -x "${SCRIPT}" ]] || fail "vm-smoke.sh is missing or not executable"
bash -n "${SCRIPT}"

for required in \
    snapshot_user_plugin_state \
    snapshot_pacman_state \
    record_configured_tracking_ref \
    lifecycle-a-before-status.json \
    lifecycle-staged-status.json \
    lifecycle-b-booted-status.json \
    lifecycle-a-rollback-status.json \
    update-booted-status.json \
    user-plugin-state-a-before.tsv \
    user-plugin-state-b-booted.tsv \
    user-plugin-state-a-rollback.tsv \
    user-plugin-state-b-update.tsv \
    pacman.log \
    pacman-db-log \
    gate-3-5.receipt.json \
    OMARCHY_EXPECTED_TRACKING_REF \
    OMARCHY_ASSERT_TESTING_REF; do
    grep -Fq -- "$required" "${SCRIPT}" || fail "vm lifecycle harness is missing ${required}"
done

grep -Eq 'status\.staged\.image\.imageDigest == \$digest' "${SCRIPT}" ||
    fail "Gate 3 does not assert the exact staged B digest"
grep -Eq 'status\.booted\.image\.imageDigest == \$digest' "${SCRIPT}" ||
    fail "Gate 3/5 does not assert the exact booted digest"
grep -Fq 'pre_stage: "none"' "${SCRIPT}" ||
    fail "Gate 5 receipt does not record that no pre-stage occurred"
grep -Fq 'omarchy update -y' "${SCRIPT}" ||
    fail "Gate 5 does not invoke the real Omarchy updater"

gate5_block="$(sed -n '/# Gate 5:/,/printf.*gate-3-5.receipt/p' "${SCRIPT}")"
[[ -n "${gate5_block}" ]] || fail "Gate 5 block could not be isolated"
if grep -Fq 'bootc switch --' <<<"${gate5_block}"; then
    fail "Gate 5 still pre-stages B with bootc switch"
fi
grep -Fq 'upgrade --check' <<<"${gate5_block}" ||
    fail "Gate 5 does not prove bootc upgrade --check"
grep -Fq 'upgrade' <<<"${gate5_block}" ||
    fail "Gate 5 does not prove a bootc upgrade operation"

if grep -Fq 'RUN_LIFECYCLE_ACCEPTANCE' "${SCRIPT}"; then
    fail "Gate 3/5 lifecycle is optional"
fi

grep -Fq 'cmp -s "${ARTIFACT_DIR}/user-plugin-state-a-before.tsv"' "${SCRIPT}" ||
    fail "Gate 3/5 does not compare persistent user/plugin state"
grep -Fq 'pacman_after_update_hash' "${SCRIPT}" ||
    fail "Gate 5 does not compare the pacman DB/log snapshot after update"
grep -Fq 'pacman_after_reboot_hash' "${SCRIPT}" ||
    fail "Gate 5 does not compare the pacman DB/log snapshot after reboot"
grep -Fq '.spec.image.image' "${SCRIPT}" ||
    fail "configured image tracking ref is not recorded"
grep -Fq 'source_sha: $source_sha' "${SCRIPT}" ||
    fail "Gate 3/5 JSON receipt lacks source identity"

printf 'PASS: Gate 3/5 lifecycle harness contract\n'
