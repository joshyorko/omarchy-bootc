#!/usr/bin/env bash

write_gate4_receipt() {
    local output="$1"
    local dakota_ref="$2"
    local dakota_tracking_ref="$3"
    local dakota_digest="$4"
    local dakota_overlay_digest="$5"
    local quattro_ref="$6"
    local quattro_tracking_ref="$7"
    local quattro_digest="$8"
    local source_sha="$9"
    local source_backend="${10}"
    local quattro_backend="${11}"
    local reverse_backend="${12}"

    jq -n \
        --arg dakota_ref "${dakota_ref}" \
        --arg dakota_tracking_ref "${dakota_tracking_ref}" \
        --arg dakota_digest "${dakota_digest}" \
        --arg dakota_overlay_digest "${dakota_overlay_digest}" \
        --arg quattro_ref "${quattro_ref}" \
        --arg quattro_tracking_ref "${quattro_tracking_ref}" \
        --arg quattro_digest "${quattro_digest}" \
        --arg source_sha "${source_sha}" \
        --arg source_backend "${source_backend}" \
        --arg quattro_backend "${quattro_backend}" \
        --arg reverse_backend "${reverse_backend}" \
        '{schema:"omarchy-bootc.gate4-dakota-roundtrip/v1",gate:4,result:"passed",
          runtime_proven:true,hardware_scope:"x86_64 UEFI QEMU; no physical hardware claim",
          source:{immutable_ref:$dakota_ref,tracking_ref:$dakota_tracking_ref,digest:$dakota_digest,
            acceptance_overlay_digest:$dakota_overlay_digest,booted_backend:$source_backend},
          forward:{accepted_ref:$quattro_ref,tracking_ref:$quattro_tracking_ref,digest:$quattro_digest,
            booted_backend:$quattro_backend,adoption:"complete"},
          reverse:{tracking_ref:$dakota_tracking_ref,digest:$dakota_digest,booted_backend:$reverse_backend,
            user_home_preserved:true},
          source_sha:$source_sha,adoption_recovery_contract:"passed"}' \
        >"${output}"
}
