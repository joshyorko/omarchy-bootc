#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

a="sha256:$(printf '%064d' 0 | tr 0 a)"
b="sha256:$(printf '%064d' 0 | tr 0 b)"
mkdir -p "$tmp/bin" "$tmp/home/.local/state/omarchy-bootc"
: >"$tmp/sudo.log"
: >"$tmp/actions.log"
: >"$tmp/root-marker"

cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_SUDO_LOG"
[[ ${1:-} == -n && ${2:-} == -- && $# == 3 ]] || {
    echo 'fake sudo requires noninteractive command-scoped invocation' >&2
    exit 1
}
case "$3" in
    /usr/libexec/omarchy-bootc-status)
        cat "$FAKE_STATUS_JSON"
        ;;
    /usr/libexec/omarchy-bootc-clear-transaction)
        rm -f -- "$FAKE_ROOT_MARKER"
        ;;
    *)
        echo "unexpected sudo command: $3" >&2
        exit 1
        ;;
esac
EOF
cat >"$tmp/bin/omarchy-migrate" <<'EOF'
#!/usr/bin/env bash
printf 'migrate\n' >>"$FAKE_ACTIONS_LOG"
EOF
cat >"$tmp/bin/omarchy-hook" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == post-update ]] || exit 1
printf 'hook\n' >>"$FAKE_ACTIONS_LOG"
EOF
chmod +x "$tmp/bin"/*

cat >"$tmp/finalize" <<EOF
$(sed \
    -e "s|^source /usr/lib/omarchy-bootc/update-common.sh$|source \"${ROOT_DIR}/custom/bootc/omarchy-bootc-common.sh\"|" \
    "${ROOT_DIR}/custom/bootc/omarchy-bootc-finalize")
EOF
chmod +x "$tmp/finalize"
export PATH="$tmp/bin:$PATH"
export HOME="$tmp/home"
export FAKE_SUDO_LOG="$tmp/sudo.log" FAKE_ACTIONS_LOG="$tmp/actions.log"
export FAKE_STATUS_JSON="$tmp/status.json" FAKE_ROOT_MARKER="$tmp/root-marker"

write_status() {
    local digest="$1"
    jq -n --arg digest "$digest" '{apiVersion:"org.containers.bootc/v1",kind:"BootcHost",
      spec:{image:{image:"ghcr.io/example/os:testing",transport:"registry"}},
      status:{booted:{image:{imageDigest:$digest,architecture:"amd64"}},staged:null,rollback:null}}' \
        >"$FAKE_STATUS_JSON"
}
printf 'status=intent\nexpected_digest=%s\n' "$b" \
    >"$HOME/.local/state/omarchy-bootc/pending-update"
chmod 0600 "$HOME/.local/state/omarchy-bootc/pending-update"

write_status "$a"
if bash "$tmp/finalize" >"$tmp/mismatch.out" 2>&1; then
    fail 'digest mismatch was accepted'
fi
[[ ! -s "$tmp/actions.log" ]] || fail 'migration or hook ran before digest verification'
[[ -e "$FAKE_ROOT_MARKER" ]] || fail 'root marker was cleared before digest verification'
[[ -e "$HOME/.local/state/omarchy-bootc/pending-update" ]] || fail 'user marker was removed after digest mismatch'

write_status "$b"
bash "$tmp/finalize" >"$tmp/match.out"
grep -Fxq migrate "$tmp/actions.log" || fail 'migration did not run after exact digest match'
grep -Fxq hook "$tmp/actions.log" || fail 'post-update hook did not run after exact digest match'
grep -Fq -- '-n -- /usr/libexec/omarchy-bootc-status' "$tmp/sudo.log" || fail 'status helper was not invoked noninteractively'
grep -Fq -- '-n -- /usr/libexec/omarchy-bootc-clear-transaction' "$tmp/sudo.log" || fail 'clear helper was not invoked noninteractively'
[[ ! -e "$HOME/.local/state/omarchy-bootc/pending-update" ]] || fail 'user marker was not removed after finalization'
[[ ! -e "$FAKE_ROOT_MARKER" ]] || fail 'root marker was not cleared after finalization'
printf 'PASS: bootc finalizer privilege boundary and digest gate\n'
