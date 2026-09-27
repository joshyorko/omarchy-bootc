#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/custom/bootc/omarchy-bootc-update"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat >"$tmp/status.json" <<'EOF'
{"spec":{"image":{"image":"ghcr.io/example/os:testing"}},"status":{"booted":{"image":{"imageDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},"staged":null,"rollback":null,"cachedUpdate":{"image":{"imageDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}}
EOF
cat >"$tmp/bootc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BOOTC_LOG"
[[ ${1:-} == upgrade && ${2:-} == --check ]]
EOF
chmod +x "$tmp/bootc"

long_name="$(printf '%0300d' 0 | tr '0' x)"
root_marker="${tmp}/${long_name}"
if env \
    OMARCHY_BOOTC_COMMON_LIB="${ROOT_DIR}/custom/bootc/omarchy-bootc-common.sh" \
    OMARCHY_BOOTC_BIN="$tmp/bootc" OMARCHY_BOOTC_STATUS_FILE="$tmp/status.json" \
    OMARCHY_BOOTC_STATE_ROOT="$tmp/root-state" OMARCHY_BOOTC_TRANSACTION_MARKER="$root_marker" \
    OMARCHY_BOOTC_UPDATE_LOCK_FILE="$tmp/update.lock" XDG_STATE_HOME="$tmp/user-state" \
    BOOTC_LOG="$tmp/bootc.log" bash "$SCRIPT" -y; then
    fail 'update proceeded despite a transaction-marker write failure'
fi
if grep -Fxq 'upgrade' "$tmp/bootc.log" 2>/dev/null; then
    fail 'bootc upgrade ran before the durable root transaction marker was written'
fi
[[ ! -e "$tmp/user-state/omarchy-bootc/pending-update" ]] || fail 'failed root marker write left an orphaned user marker'

printf 'PASS: update marker failure prevents staging\n'
