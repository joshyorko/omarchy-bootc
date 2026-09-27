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

# The supported bootc JSON contract is status.booted/staged/rollback, where a
# BootEntry carries image.imageDigest and optionally image.image. Never search
# arbitrary descendants: other deployment slots and metadata are not identity.
status_field() {
    local key="$1" status
    status="$(bootc_status_json)" || return
    jq -r --arg key "$key" '
      def digest($entry):
        if $entry == null then ""
        elif ($entry|type) != "object" then error("invalid BootEntry")
        elif ($entry.image|type) != "object" then error("invalid BootEntry.image")
        elif ($entry.image.imageDigest|type) != "string" then error("missing BootEntry.image.imageDigest")
        elif ($entry.image.imageDigest|test("^sha256:[A-Fa-f0-9]{64}$")) then $entry.image.imageDigest
        else error("invalid BootEntry image digest") end;
      if type != "object" or (.status|type) != "object" or
         (["booted","staged","rollback"] - (.status|keys)) != [] then
        error("unsupported bootc status schema") else . end
      | if (.spec|type) != "object" or (.spec.image|type) != "object" or
           (.spec.image.image|type) != "string" or (.spec.image.image|length) == 0 or
           (.spec.image.image|test("[[:space:]]")) then error("invalid configured image ref") else . end
      | if $key == "booted" then
          if .status.booted == null then error("missing booted BootEntry") else digest(.status.booted) end
        elif $key == "staged" or $key == "rollback" then
          if .status[$key] == null then "" else digest(.status[$key]) end
        elif $key == "cached" then
          if (.status|has("cachedUpdate")|not) or .status.cachedUpdate == null then ""
          else digest(.status.cachedUpdate) end
        elif $key == "tracking" then
          .spec.image.image
        else error("unknown status field") end
    ' <<<"$status"
}

status_booted_digest() { status_field booted; }
status_staged_digest() { status_field staged; }
status_rollback_digest() { status_field rollback; }
status_cached_digest() { status_field cached; }
status_tracking_ref() { status_field tracking; }

status_update_available() {
    local booted staged cached
    booted="$(status_booted_digest)" || return 2
    staged="$(status_staged_digest)" || return 2
    cached="$(status_cached_digest)" || return 2
    [[ -n "$staged" && "$staged" != "$booted" ]] && return 0
    [[ -n "$cached" && "$cached" != "$booted" ]]
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
