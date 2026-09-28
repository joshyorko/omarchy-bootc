#!/usr/bin/env bash
# jq assignment filters intentionally preserve their literal variables.
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT_DIR}/custom/bootc/omarchy-bootc-common.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# External image access is faked here only. Gate5 uses a real registry and bootc.
mkdir "$tmp/bin"
cat >"$tmp/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    inspect)
        [[ "$2" == --raw && "$3" == "$RESOLVER_REF" ]] || exit 1
        [[ "${RESOLVER_FAIL:-0}" == 0 ]] || exit 1
        cat "$RESOLVER_MANIFEST"
        ;;
    manifest-digest)
        digest="$(sha256sum "$2")"
        printf 'sha256:%s\n' "${digest%% *}"
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/skopeo"
export PATH="$tmp/bin:$PATH"
export RESOLVER_REF='docker://ghcr.io/example/os:testing'
export RESOLVER_MANIFEST="$tmp/manifest.json"
printf '%s\n' '{"schemaVersion":2,"config":{},"layers":[]}' >"$RESOLVER_MANIFEST"
resolved="$(sha256sum "$RESOLVER_MANIFEST")"
resolved="sha256:${resolved%% *}"
a="sha256:$(printf '%064d' 0 | tr 0 a)"
b="sha256:$(printf '%064d' 0 | tr 0 b)"
c="sha256:$(printf '%064d' 0 | tr 0 c)"

# shellcheck disable=SC1090
source "$COMMON"
# Keep the unit's resolver in-process privilege context; runtime uses real sudo.
run_as_root() { "$@"; }
export OMARCHY_BOOTC_STATUS_FILE="$tmp/status.json"
write_status() {
    jq -n --arg a "$a" --argjson staged "${1:-null}" --argjson cached "${2:-null}" '
      {apiVersion:"org.containers.bootc/v1",kind:"BootcHost",
       spec:{image:{image:"ghcr.io/example/os:testing",transport:"registry",signature:"containerPolicy"}},
       status:{booted:{image:{image:{image:"ghcr.io/example/os:testing",transport:"registry"},
         imageDigest:$a,architecture:"amd64",version:null,timestamp:null},
         cachedUpdate:$cached,composefs:{verity:"not-an-image-digest"}},staged:$staged,rollback:null}}
    ' >"$OMARCHY_BOOTC_STATUS_FILE"
}
change_status() {
    jq "$@" "$OMARCHY_BOOTC_STATUS_FILE" >"$tmp/next.json"
    mv "$tmp/next.json" "$OMARCHY_BOOTC_STATUS_FILE"
}
write_status "{\"image\":{\"imageDigest\":\"$b\"}}"
change_status --arg c "$c" '.status.rollback = {image:{imageDigest:$c}}'
[[ "$(status_booted_digest)" == "$a" ]] || fail 'booted identity confused with another slot'
[[ "$(status_rollback_digest)" == "$c" ]] || fail 'rollback identity was not parsed'
[[ "$(status_update_available)" == "$b" ]] || fail 'staged update was not authoritative'

write_status null "{\"imageDigest\":\"$b\"}"
[[ "$(status_update_available)" == "$b" ]] || fail 'cached update metadata was ignored'
write_status
[[ -z "$(status_staged_digest)" && -z "$(status_cached_digest)" ]] || fail 'null slots were not empty'
[[ "$(status_update_available)" == "$resolved" ]] || fail 'null cachedUpdate did not resolve the registry candidate'
change_status --arg digest "$resolved" '.status.booted.image.imageDigest = $digest'
if status_update_available; then fail 'same registry digest reported an update'; else rc=$?; fi
[[ "$rc" == 1 ]] || fail 'same digest was treated as an error'
export RESOLVER_FAIL=1
if status_update_available; then fail 'failed resolution reported an update'; else rc=$?; fi
[[ "$rc" == 2 ]] || fail 'failed resolution was treated as up to date'
unset RESOLVER_FAIL

# A staged copy of the booted image must not hide a new registry candidate.
write_status "{\"image\":{\"imageDigest\":\"$a\"}}"
[[ "$(status_update_available)" == "$resolved" ]] || fail 'same-image stage hid the registry update'

# Tracking names are split from their transport in the native bootc API.
for transport in registry oci oci-archive docker-archive containers-storage dir; do
    ref='example/os:testing'
    if [[ "$transport" == registry ]]; then ref='10.0.2.2:5000/omarchy:acceptance'; fi
    change_status --arg transport "$transport" --arg ref "$ref" '.spec.image.transport=$transport | .spec.image.image=$ref'
    RESOLVER_REF="${transport}:${ref}"
    if [[ "$transport" == registry ]]; then RESOLVER_REF="docker://${ref}"; fi
    [[ "$(status_candidate_digest)" == "$resolved" ]] || fail "failed transport ${transport}"
done
change_status '.spec.image.transport="unsupported"'
if status_update_available >/dev/null 2>&1; then fail 'unsupported transport accepted'; else rc=$?; fi
[[ "$rc" == 2 ]] || fail 'unsupported transport was treated as up to date'

# Older bootc status documents may omit the transport; registry is the
# supported default for an image reference.
write_status
change_status 'del(.spec.image.transport)'
export RESOLVER_REF='docker://ghcr.io/example/os:testing'
[[ "$(status_candidate_digest)" == "$resolved" ]] ||
    fail 'missing image transport did not default to registry'

write_status
export RESOLVER_REF='docker://ghcr.io/example/os:testing'
jq -n --arg b "$b" --arg c "$c" '{schemaVersion:2,manifests:[
  {digest:$c,platform:{os:"linux",architecture:"arm64"}},
  {digest:$b,platform:{os:"linux",architecture:"amd64"}}]}' >"$RESOLVER_MANIFEST"
[[ "$(status_candidate_digest)" == "$b" ]] || fail 'index digest confused with platform digest'
jq '.manifests += [.manifests[1]]' "$RESOLVER_MANIFEST" >"$tmp/ambiguous.json"
mv "$tmp/ambiguous.json" "$RESOLVER_MANIFEST"
if status_update_available >/dev/null 2>&1; then fail 'ambiguous platform accepted'; else rc=$?; fi
[[ "$rc" == 2 ]] || fail 'ambiguous platform was treated as up to date'
printf '%s\n' '{"schemaVersion":2,"manifests":[{"digest":"bad","platform":{"os":"linux","architecture":"amd64"}}]}' >"$RESOLVER_MANIFEST"
if status_candidate_digest >/dev/null 2>&1; then fail 'non-exact resolved digest accepted'; fi
printf '%s\n' 'not-json' >"$RESOLVER_MANIFEST"
if status_candidate_digest >/dev/null 2>&1; then fail 'invalid registry manifest accepted'; fi

for filter in 'null' 'del(.status.staged)' '.status.booted=null' '.status.booted.image.imageDigest="bad"' '.spec.image.image="bad ref"' '.status.booted.cachedUpdate={imageDigest:"bad"}'; do
    write_status
    change_status "$filter"
    if status_candidate_digest >/dev/null 2>&1; then fail "malformed status accepted: ${filter}"; fi
done
printf 'PASS: bootc slot identity and composefs candidate resolution\n'
