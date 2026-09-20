#!/usr/bin/env bash
set -euo pipefail

OMARCHY_BOOTC_BIN="${OMARCHY_BOOTC_BIN:-bootc}"
OMARCHY_BOOTC_STATE_ROOT="${OMARCHY_BOOTC_STATE_ROOT:-/var/lib/omarchy-bootc/updates}"

bootc_status_json() {
    if [[ -n "${OMARCHY_BOOTC_STATUS_FILE:-}" ]]; then
        cat "$OMARCHY_BOOTC_STATUS_FILE"
    else
        "$OMARCHY_BOOTC_BIN" status --format=json
    fi
}

status_digests() {
    bootc_status_json | grep -Eio 'sha256:[[:xdigit:]]{64}' | awk '!seen[$0]++'
}

status_booted_digest() {
    local status digest
    status="$(bootc_status_json)"
    if command -v jq >/dev/null 2>&1; then
        digest="$(jq -r '.. | objects | select(.booted == true or .state == "booted") | tostring' <<<"$status" |
            grep -Eio 'sha256:[[:xdigit:]]{64}' | head -n 1 || true)"
    fi
    [[ -n "${digest:-}" ]] || digest="$(printf '%s\n' "$status" | grep -Eio 'sha256:[[:xdigit:]]{64}' | head -n 1 || true)"
    printf '%s\n' "$digest"
}

status_staged_digest() {
    local status digest
    status="$(bootc_status_json)"
    if command -v jq >/dev/null 2>&1; then
        digest="$(jq -r '.. | objects | select(.booted == false or .state == "staged" or .state == "pending") | tostring' <<<"$status" |
            grep -Eio 'sha256:[[:xdigit:]]{64}' | head -n 1 || true)"
    fi
    [[ -n "${digest:-}" ]] || digest="$(status_digests | sed -n '2p')"
    printf '%s\n' "$digest"
}

status_update_available() {
    local status booted staged
    status="$(bootc_status_json)"
    if grep -Eqi '"(update_available|updates_available|upgrade_available)"[[:space:]]*:[[:space:]]*true' <<<"$status"; then
        return 0
    fi
    booted="$(status_booted_digest)"
    staged="$(status_staged_digest)"
    [[ -n "$staged" && "$staged" != "$booted" ]]
}

run_as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || {
            echo 'bootc update requires sudo' >&2
            return 1
        }
        sudo -- "$@"
    fi
}
