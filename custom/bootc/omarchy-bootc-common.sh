#!/usr/bin/env bash
set -euo pipefail

OMARCHY_BOOTC_BIN="${OMARCHY_BOOTC_BIN:-bootc}"
OMARCHY_BOOTC_STATE_ROOT="${OMARCHY_BOOTC_STATE_ROOT:-/var/lib/omarchy-bootc/updates}"

bootc_status_json() {
    if [[ -n "${OMARCHY_BOOTC_STATUS_FILE:-}" ]]; then
        cat "$OMARCHY_BOOTC_STATUS_FILE"
    elif [[ -z "${OMARCHY_BOOTC_STATUS_HELPER:-}" ]]; then
        run_as_root "$OMARCHY_BOOTC_BIN" status --format=json
    elif [[ "${OMARCHY_BOOTC_STATUS_HELPER}" == /usr/libexec/omarchy-bootc-status ]]; then
        run_as_root_noninteractive "$OMARCHY_BOOTC_STATUS_HELPER"
    else
        echo 'invalid bootc status helper' >&2
        return 1
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
      def cached_digest($entry):
        if $entry == null then ""
        elif ($entry|type) != "object" then error("invalid cached ImageStatus")
        elif ($entry.imageDigest|type) != "string" then error("missing cached ImageStatus.imageDigest")
        elif ($entry.imageDigest|test("^sha256:[A-Fa-f0-9]{64}$")) then $entry.imageDigest
        else error("invalid cached ImageStatus digest") end;
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
          if .status.booted == null then ""
          elif (.status.booted|type) != "object" then error("invalid booted BootEntry")
          elif (.status.booted|has("cachedUpdate")|not) or .status.booted.cachedUpdate == null then ""
          else cached_digest(.status.booted.cachedUpdate) end
        elif $key == "tracking" then
          .spec.image.image
        elif $key == "transport" then
          if (.spec.image|has("transport")|not) then "registry"
          elif (.spec.image.transport|type) == "string" then .spec.image.transport
          else error("invalid image transport") end
        elif $key == "architecture" then
          if (.status.booted.image.architecture|type) == "string" then .status.booted.image.architecture
          else error("missing booted image architecture") end
        else error("unknown status field") end
    ' <<<"$status"
}

status_booted_digest() { status_field booted; }
status_staged_digest() { status_field staged; }
status_rollback_digest() { status_field rollback; }
status_cached_digest() { status_field cached; }
status_tracking_ref() { status_field tracking; }

# Composefs bootc 1.16.13 never populates cachedUpdate, even after --check.
# Inspect the configured transport using the same root registry/auth settings.
# Do not override TLS or signature policy: bootc still owns check and staging.
status_resolved_digest() (
    local ref transport manifest digest architecture
    ref="$(status_tracking_ref)" || return
    transport="$(status_field transport)" || return
    case "$transport" in
        registry) ref="docker://${ref}" ;;
        oci|oci-archive|docker-archive|containers-storage|dir) ref="${transport}:${ref}" ;;
        *) echo "unsupported bootc image transport: ${transport}" >&2; return 1 ;;
    esac
    manifest="$(mktemp)" || return
    trap 'rm -f -- "$manifest"' EXIT
    run_as_root skopeo inspect --raw "$ref" >"$manifest" || return
    if jq -e 'has("manifests")' "$manifest" >/dev/null; then
        # Composefs records the platform manifest, not the multiarch index.
        # Fail closed on ambiguous variants rather than guess a digest.
        architecture="$(status_field architecture)" || return
        digest="$(jq -er --arg arch "$architecture" '
          [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch)]
          | if length == 1 then .[0].digest else error("ambiguous or missing image platform") end
        ' "$manifest")" || return
    else
        jq -e '.schemaVersion == 2 and (.config|type) == "object" and (.layers|type) == "array"' \
            "$manifest" >/dev/null || return
        digest="$(skopeo manifest-digest "$manifest")" || return
    fi
    [[ "$digest" =~ ^sha256:[[:xdigit:]]{64}$ ]] || {
        echo 'image resolver did not return an exact sha256 digest' >&2
        return 1
    }
    printf '%s\n' "$digest"
)

status_candidate_digest() {
    local booted staged candidate
    booted="$(status_booted_digest)" || return
    staged="$(status_staged_digest)" || return
    if [[ -n "$staged" && "$staged" != "$booted" ]]; then
        printf '%s\n' "$staged"
        return 0
    fi
    candidate="$(status_cached_digest)" || return
    if [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
    else
        status_resolved_digest
    fi
}

# Print the candidate only when an update exists; resolution errors are not
# "up to date". Callers must preserve the distinction between exit 1 and 2.
status_update_available() {
    local booted candidate
    booted="$(status_booted_digest)" || return 2
    candidate="$(status_candidate_digest)" || return 2
    [[ "$candidate" != "$booted" ]] || return 1
    printf '%s\n' "$candidate"
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
run_as_root_noninteractive() {
    if (( EUID == 0 )); then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || {
            echo 'bootc update requires sudo' >&2
            return 1
        }
        sudo -n -- "$@"
    fi
}
