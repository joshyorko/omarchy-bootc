#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT_DIR}/custom/bootc/omarchy-bootc-common.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat >"$tmp/status.json" <<'EOF'
{"status":{"rollback":{"image":{"imageDigest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","image":"old"}},"staged":{"image":{"imageDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","image":"candidate"}},"booted":{"image":{"imageDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","image":"current"}},"cachedUpdate":null},"spec":{"image":{"image":"ghcr.io/example/os:testing"}}}
EOF
source "$COMMON"
export OMARCHY_BOOTC_STATUS_FILE="$tmp/status.json"
[[ "$(status_booted_digest)" == sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || fail 'booted slot digest was not authoritative'
[[ "$(status_staged_digest)" == sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]] || fail 'staged slot digest was not parsed'
[[ "$(status_rollback_digest)" == sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc ]] || fail 'rollback slot digest was not parsed'
status_update_available || fail 'staged update was not detected'

cat >"$tmp/status.json" <<'EOF'
{"spec":{"image":{"image":"ghcr.io/example/os:testing"}},"status":{"booted":{"image":{"imageDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},"staged":null,"rollback":null,"cachedUpdate":{"image":{"imageDigest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}}}}
EOF
[[ -z "$(status_staged_digest)" ]] || fail 'null staged slot should mean no stage'
status_update_available || fail 'cached update metadata was ignored'

cat >"$tmp/status.json" <<'EOF'
{"spec":{"image":{"image":"ghcr.io/example/os:testing"}},"status":{"booted":{"image":{"imageDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},"staged":null,"rollback":null}}
EOF
if status_update_available; then fail 'no-stage status reported an update'; fi

for bad in 'null' '{"deployments":[{"booted":true,"name":"bluefin","image":{"imageDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}' '{"status":{"booted":null,"staged":null,"rollback":null}}' '{"spec":{"image":{"image":"ghcr.io/example/os:testing"}},"status":{"booted":{"image":{"imageDigest":"not-a-digest"}},"staged":null,"rollback":null}}' '{"spec":{"image":{"image":"bad ref"}},"status":{"booted":{"image":{"imageDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},"staged":null,"rollback":null}}' '{"spec":{"image":{"image":"ghcr.io/example/os:testing"}},"status":{"booted":{"image":{"imageDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},"staged":null}}'; do
    printf '%s\n' "$bad" >"$tmp/status.json"
    if status_booted_digest >/dev/null 2>&1; then fail "malformed or unsupported status accepted: ${bad}"; fi
done

printf 'PASS: strict bootc identity parser\n'
