#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# This fixture exercises a user-session finalizer and its scoped sudo calls.
# A root build worker must actually drop privileges, not invoke installed helpers.
if (( EUID == 0 )); then
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/codex-finalizer-user-XXXXXXXX")
    trap 'rm -rf -- "$fixture"' EXIT
    install -d -m 0755 "$fixture/tests/fixtures/upstream" "$fixture/custom/bootc"
    chmod 0711 "$fixture"
    cp -- "$ROOT_DIR/tests/test-update-finalizer.sh" "$fixture/tests/"
    cp -- "$ROOT_DIR/tests/fixtures/upstream/omarchy-migrate-ac2690cd.sh" "$fixture/tests/fixtures/upstream/"
    cp -- "$ROOT_DIR/custom/bootc/omarchy-bootc-common.sh" \
        "$ROOT_DIR/custom/bootc/omarchy-bootc-finalize" "$fixture/custom/bootc/"
    runuser -u nobody -- bash "$fixture/tests/test-update-finalizer.sh"
    exit
fi
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
        [[ ${FAKE_CLEAR_RC:-0} == 0 ]] || exit "$FAKE_CLEAR_RC"
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
[[ ${1:-} != --pending ]] || exit 1
printf 'migrate\n' >>"$FAKE_ACTIONS_LOG"
EOF
cat >"$tmp/bin/omarchy-hook" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == post-update ]] || exit 1
[[ ${FAKE_HOOK_RC:-0} == 0 ]] || exit "$FAKE_HOOK_RC"
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

# Run the actual pinned upstream runner, not a migration double. Only its lock
# path and elapsed wait are redirected; migration discovery/execution/markers
# and --pending exit semantics are unchanged.
upstream="$ROOT_DIR/tests/fixtures/upstream/omarchy-migrate-ac2690cd.sh"
upstream_hash="$(sha256sum "$upstream")"
[[ ${upstream_hash%% *} == 0c14cb7853174d5289172496e22c1bd444b20c00c1aefd589e1faa3ae6941abe ]] || fail 'pinned upstream migration runner drifted'
export OMARCHY_PATH="$tmp/upstream" OMARCHY_MIGRATION_STATE="$tmp/migrations"
export FAKE_MIGRATION_EFFECT="$tmp/migration-effect"
mkdir -p "$OMARCHY_PATH/migrations"
# shellcheck disable=SC2016 # The migration expands its own controlled environment.
printf 'printf "applied\\n" >>"$FAKE_MIGRATION_EFFECT"\n' >"$OMARCHY_PATH/migrations/0001.sh"
sed "s|local lock_file=/var/lib/pacman/db.lck|local lock_file=$tmp/pacman.lock|" "$upstream" >"$tmp/bin/omarchy-migrate"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"
printf 'status=intent\nexpected_digest=%s\n' "$b" >"$HOME/.local/state/omarchy-bootc/pending-update"
chmod 0600 "$HOME/.local/state/omarchy-bootc/pending-update"
: >"$FAKE_ROOT_MARKER"
: >"$tmp/actions.log"
: >"$tmp/pacman.lock"
if bash "$tmp/finalize" >"$tmp/deferred.out" 2>&1; then
    fail 'real pinned runner deferred work but finalizer reported success'
fi
[[ -e "$FAKE_ROOT_MARKER" && -e "$HOME/.local/state/omarchy-bootc/pending-update" ]] || fail 'deferred migration lost update intent'
[[ ! -e "$FAKE_MIGRATION_EFFECT" && ! -e "$OMARCHY_MIGRATION_STATE/0001.sh" && ! -s "$tmp/actions.log" ]] || fail 'deferred migration ran work or post-update hook'
rm "$tmp/pacman.lock"
cp "$OMARCHY_PATH/migrations/0001.sh" "$tmp/successful-migration"
printf 'exit 23\n' >"$OMARCHY_PATH/migrations/0001.sh"
if bash "$tmp/finalize" >"$tmp/migration-error.out" 2>&1; then fail 'real migration failure certified completion'; fi
[[ -e "$FAKE_ROOT_MARKER" && -e "$HOME/.local/state/omarchy-bootc/pending-update" ]] || fail 'failed migration lost intent'
[[ ! -e "$OMARCHY_MIGRATION_STATE/0001.sh" && ! -s "$tmp/actions.log" ]] || fail 'failed migration was acknowledged or ran hook'
cp "$tmp/successful-migration" "$OMARCHY_PATH/migrations/0001.sh"
bash "$tmp/finalize" >"$tmp/retry.out" 2>&1
grep -Fxq applied "$FAKE_MIGRATION_EFFECT" || fail 'real upstream migration did not apply on retry'
[[ -f "$OMARCHY_MIGRATION_STATE/0001.sh" ]] || fail 'real upstream migration did not acknowledge application'
[[ ! -e "$FAKE_ROOT_MARKER" && ! -e "$HOME/.local/state/omarchy-bootc/pending-update" ]] || fail 'successful migration retry retained intent'
bash "$tmp/finalize"
[[ $(wc -l <"$FAKE_MIGRATION_EFFECT") == 1 ]] || fail 'finalization replayed an already applied migration'
for failure in hook clear; do
    export FAKE_HOOK_RC=0 FAKE_CLEAR_RC=0
    if [[ $failure == hook ]]; then export FAKE_HOOK_RC=24; else export FAKE_CLEAR_RC=25; fi
    printf 'expected_digest=%s\n' "$b" >"$HOME/.local/state/omarchy-bootc/pending-update"
    chmod 0600 "$HOME/.local/state/omarchy-bootc/pending-update"
    : >"$FAKE_ROOT_MARKER"
    if bash "$tmp/finalize" >"$tmp/$failure-error.out" 2>&1; then fail "$failure failure certified completion"; fi
    [[ -e "$FAKE_ROOT_MARKER" && -e "$HOME/.local/state/omarchy-bootc/pending-update" ]] || fail "$failure failure lost intent"
done
unset FAKE_HOOK_RC FAKE_CLEAR_RC
for query_status in 1 7; do
    cat >"$tmp/bin/omarchy-migrate" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --pending ]]; then echo 'pending query failed' >&2; exit "$FAKE_QUERY_STATUS"; fi
EOF
    export FAKE_QUERY_STATUS="$query_status"
    printf 'expected_digest=%s\n' "$b" >"$HOME/.local/state/omarchy-bootc/pending-update"
    chmod 0600 "$HOME/.local/state/omarchy-bootc/pending-update"
    : >"$FAKE_ROOT_MARKER"
    if bash "$tmp/finalize" >"$tmp/query-error.out" 2>&1; then fail 'pending query error certified completion'; fi
    [[ -e "$FAKE_ROOT_MARKER" && -e "$HOME/.local/state/omarchy-bootc/pending-update" ]] || fail 'query error lost intent'
done
printf 'PASS: digest/privilege gate and real pinned-runner defer, retry, apply and acknowledgment\n'
