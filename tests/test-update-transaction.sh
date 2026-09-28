#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/custom/bootc/omarchy-bootc-update"
AVAILABLE="${ROOT_DIR}/custom/bootc/omarchy-bootc-update-available"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
a="sha256:$(printf '%064d' 0 | tr 0 a)"
c="sha256:$(printf '%064d' 0 | tr 0 c)"

# Unit doubles for external operations, not a substitute for the registry VM gate.
mkdir "$tmp/bin"
cat >"$tmp/bin/bootc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$BOOTC_LOG"
case "$*" in
    'upgrade --check') exit "${CHECK_RC:-0}" ;;
    upgrade)
        [[ -f "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" ]] || exit 10
        exit_code="${UPGRADE_RC:-0}"
        [[ "$exit_code" == 0 ]] || exit "$exit_code"
        jq --arg digest "$STAGE_DIGEST" '.status.staged={image:{imageDigest:$digest}}' \
            "$OMARCHY_BOOTC_TEST_STATUS_FILE" >"${OMARCHY_BOOTC_TEST_STATUS_FILE}.next"
        mv "${OMARCHY_BOOTC_TEST_STATUS_FILE}.next" "$OMARCHY_BOOTC_TEST_STATUS_FILE"
        ;;
    *) exit 1 ;;
esac
EOF
cat >"$tmp/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    inspect)
        [[ "$2" == --raw && "$3" == docker://ghcr.io/example/os:testing ]] || exit 1
        [[ "${RESOLVER_RC:-0}" == 0 ]] || exit "$RESOLVER_RC"
        cat "$RESOLVER_MANIFEST"
        ;;
    manifest-digest)
        digest="$(sha256sum "$2")"
        printf 'sha256:%s\n' "${digest%% *}"
        ;;
    *) exit 1 ;;
esac
EOF
# Keep the isolated fixture executable as a regular user too.
cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != -- ]] || shift
exec "$@"
EOF
cat >"$tmp/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/chown"
chmod +x "$tmp/bin/flock"
chmod +x "$tmp/bin/bootc" "$tmp/bin/skopeo" "$tmp/bin/sudo"
export PATH="$tmp/bin:$PATH"
export OMARCHY_BOOTC_TEST_BIN="$tmp/bin/bootc"
export RESOLVER_MANIFEST="$tmp/manifest.json"
printf '%s\n' '{"schemaVersion":2,"config":{},"layers":[]}' >"$RESOLVER_MANIFEST"
b="$(sha256sum "$RESOLVER_MANIFEST")"
b="sha256:${b%% *}"
export STAGE_DIGEST="$b"
# SUDO_USER is unrelated to these isolated per-test directories.
unset SUDO_USER
make_test_script() {
    local input="$1" output="$2"
    sed \
        -e "s|^source /usr/lib/omarchy-bootc/update-common.sh$|source \"${ROOT_DIR}/custom/bootc/omarchy-bootc-common.sh\"|" \
        -e 's|^export OMARCHY_BOOTC_BIN=/usr/bin/bootc$|export OMARCHY_BOOTC_BIN="${OMARCHY_BOOTC_TEST_BIN:?}"|' \
        -e 's|^export OMARCHY_BOOTC_STATUS_FILE=$|export OMARCHY_BOOTC_STATUS_FILE="${OMARCHY_BOOTC_TEST_STATUS_FILE:?}"|' \
        -e 's|^export OMARCHY_BOOTC_STATE_ROOT=/var/lib/omarchy-bootc/updates$|export OMARCHY_BOOTC_STATE_ROOT="${OMARCHY_BOOTC_TEST_STATE_ROOT:?}"|' \
        -e 's|^export OMARCHY_BOOTC_UPDATE_LOCK_FILE=/run/lock/omarchy-update.lock$|export OMARCHY_BOOTC_UPDATE_LOCK_FILE="${OMARCHY_BOOTC_TEST_UPDATE_LOCK_FILE:?}"|' \
        -e 's|^export OMARCHY_BOOTC_TRANSACTION_MARKER=/var/lib/omarchy-bootc/updates/pending-update$|export OMARCHY_BOOTC_TRANSACTION_MARKER="${OMARCHY_BOOTC_TEST_TRANSACTION_MARKER:?}"|' \
        -e 's|^state_home="${user_home}/.local/state"$|state_home="${OMARCHY_BOOTC_TEST_STATE_HOME:?}"|' \
        "$input" >"$output"
    chmod 0755 "$output"
}
make_test_script "${SCRIPT}" "$tmp/omarchy-bootc-update"
make_test_script "${AVAILABLE}" "$tmp/omarchy-bootc-update-available"
SCRIPT="$tmp/omarchy-bootc-update"
AVAILABLE="$tmp/omarchy-bootc-update-available"

setup_case() {
    local case_dir="$tmp/$1"
    mkdir "$case_dir"
    export OMARCHY_BOOTC_TEST_STATUS_FILE="$case_dir/status.json"
    export OMARCHY_BOOTC_TEST_STATE_ROOT="$case_dir/root-state"
    export OMARCHY_BOOTC_TEST_TRANSACTION_MARKER="$case_dir/root-state/pending-update"
    export OMARCHY_BOOTC_TEST_UPDATE_LOCK_FILE="$case_dir/update.lock"
    export OMARCHY_BOOTC_TEST_STATE_HOME="$case_dir/user-state"
    export BOOTC_LOG="$case_dir/bootc.log"
    : >"$BOOTC_LOG"
    export CHECK_RC=0 UPGRADE_RC=0 RESOLVER_RC=0 STAGE_DIGEST="$b"
    jq -n --arg a "$a" '{apiVersion:"org.containers.bootc/v1",kind:"BootcHost",
      spec:{image:{image:"ghcr.io/example/os:testing",transport:"registry",signature:"containerPolicy"}},
      status:{booted:{image:{image:{image:"ghcr.io/example/os:testing",transport:"registry"},
        imageDigest:$a,architecture:"amd64",version:null,timestamp:null},
        cachedUpdate:null,composefs:{verity:"not-an-image-digest"}},staged:null,rollback:null}}
    ' >"$OMARCHY_BOOTC_TEST_STATUS_FILE"
}
assert_unstaged() {
    [[ "$(jq -r '.status.staged' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == null ]] || fail 'failed preflight staged an image'
    [[ ! -e "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" ]] || fail 'failed preflight created a root intent'
    [[ ! -e "$OMARCHY_BOOTC_TEST_STATE_HOME/omarchy-bootc/pending-update" ]] || fail 'failed preflight left a user intent'
    if grep -Fxq upgrade "$BOOTC_LOG"; then fail 'failed preflight invoked upgrade'; fi
}

if (( EUID == 0 )); then
setup_case composefs
bash "$SCRIPT" -y >"$tmp/update.out"
[[ "$(jq -r '.status.staged.image.imageDigest' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == "$b" ]] || fail 'ordinary null-cachedUpdate path did not stage B'
[[ "$(cat "$BOOTC_LOG")" == $'upgrade --check\nupgrade' ]] || fail 'ordinary path did not check then stage'
grep -Fxq "expected_digest=$b" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" || fail 'root intent did not retain exact resolved digest'
[[ "$(stat -c '%a' "$OMARCHY_BOOTC_TEST_UPDATE_LOCK_FILE")" == 660 ]] ||
    fail 'update lock is not restricted to its owner and group'
initiating_user="$(id -un)"
initiating_home="$(getent passwd "$initiating_user" | cut -d: -f6)"
setup_case initiating-user
export SUDO_USER="$initiating_user"
bash "$SCRIPT" -y >"$tmp/initiating-user.out"
grep -Fxq "user=$initiating_user" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" ||
    fail 'root invocation did not retain the initiating user'
grep -Fxq "home=$initiating_home" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" ||
    fail 'root invocation did not retain the initiating home'
[[ "$(stat -c '%u:%a' "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER")" == "$(id -u):600" ]] ||
    fail 'root transaction marker has the wrong owner or mode'
[[ "$(stat -c '%u:%a' "$OMARCHY_BOOTC_TEST_STATE_HOME/omarchy-bootc/pending-update")" == "$(id -u):600" ]] ||
    fail 'user transaction marker has the wrong owner or mode'


else
printf 'SKIP: root-owned marker transaction cases require root; retaining preflight checks\n'
fi
setup_case unsupported-option
unsupported_status=0
if bash "$SCRIPT" --unsupported >"$tmp/unsupported.out" 2>&1; then
    fail 'unsupported updater option was accepted'
else
    unsupported_status=$?
fi
[[ "$unsupported_status" == 2 ]] || fail 'unsupported updater option returned the wrong status'
grep -Fq 'omarchy update: unsupported option --unsupported' "$tmp/unsupported.out" ||
    fail 'unsupported updater option was not reported'
assert_unstaged
setup_case symlink-marker
mkdir -p "$OMARCHY_BOOTC_TEST_STATE_HOME"
ln -s "$tmp/symlink-target" "$OMARCHY_BOOTC_TEST_STATE_HOME/omarchy-bootc"
if bash "$SCRIPT" -y >"$tmp/symlink.out" 2>&1; then
    fail 'symlinked user marker directory was accepted'
fi
grep -Fq 'refusing a symlinked update marker directory' "$tmp/symlink.out" ||
    fail 'symlinked user marker directory was not rejected'
assert_unstaged


setup_case check-failure
export CHECK_RC=1
if bash "$SCRIPT" -y; then fail 'failed check was accepted'; fi
assert_unstaged

setup_case no-update
jq --arg b "$b" '.status.booted.image.imageDigest=$b' "$OMARCHY_BOOTC_TEST_STATUS_FILE" >"$tmp/status.next"
mv "$tmp/status.next" "$OMARCHY_BOOTC_TEST_STATUS_FILE"
bash "$SCRIPT" -y >"$tmp/update.out"
grep -Fxq 'Omarchy image is up to date' "$tmp/update.out" ||
    fail 'updater did not report the no-update result'
assert_unstaged

setup_case marker-failure
long_name="$(printf '%0300d' 0 | tr 0 x)"
export OMARCHY_BOOTC_TEST_TRANSACTION_MARKER="${OMARCHY_BOOTC_TEST_STATE_ROOT}/${long_name}"
if bash "$SCRIPT" -y; then fail 'update proceeded despite a root marker write failure'; fi
assert_unstaged

if (( EUID == 0 )); then
setup_case upgrade-failure
export UPGRADE_RC=1
if bash "$SCRIPT" -y; then fail 'failed bootc staging was accepted'; fi
[[ "$(jq -r '.status.staged' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == null ]] || fail 'failed upgrade produced a stage'
grep -Fxq "expected_digest=$b" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" || fail 'failed staging lost the exact intent'

# A moving tag must not silently replace the candidate recorded before staging.
setup_case tag-moved
export STAGE_DIGEST="$c"
if bash "$SCRIPT" -y; then fail 'stage differing from resolved B was accepted'; fi
grep -Fxq "expected_digest=$b" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" || fail 'tag move rewrote expected identity to C'
[[ "$(jq -r '.status.staged.image.imageDigest' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == "$c" ]] || fail 'tag-move fixture did not stage C'

setup_case already-staged
jq --arg b "$b" '.status.staged={image:{imageDigest:$b}}' "$OMARCHY_BOOTC_TEST_STATUS_FILE" >"$tmp/status.next"
mv "$tmp/status.next" "$OMARCHY_BOOTC_TEST_STATUS_FILE"
export RESOLVER_RC=1
bash "$SCRIPT" -y
[[ "$(cat "$BOOTC_LOG")" == 'upgrade --check' ]] || fail 'already-staged path staged again'
grep -Fxq "expected_digest=$b" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" || fail 'already-staged intent lost B'

else
printf 'SKIP: failed-upgrade, tag-move, and already-staged cases require root-owned marker creation\n'
fi
setup_case availability
bash "$AVAILABLE" >"$tmp/available.out"
grep -Fq "candidate=$b" "$tmp/available.out" || fail 'availability did not report the resolved candidate'
[[ "$(cat "$BOOTC_LOG")" == 'upgrade --check' ]] \
    || fail 'availability helper performed an image staging operation'
assert_unstaged
# Error and no-update both use the existing nonzero CLI contract, but only an
# actual equal digest may be described as up to date; errors belong on stderr.
export RESOLVER_RC=1
if bash "$AVAILABLE" >"$tmp/available.out" 2>"$tmp/available.err"; then fail 'availability accepted failed resolution'; fi
[[ ! -s "$tmp/available.out" && -s "$tmp/available.err" ]] || fail 'resolution failure was misreported as an availability result'
export RESOLVER_RC=0
jq --arg b "$b" '.status.booted.image.imageDigest=$b' "$OMARCHY_BOOTC_TEST_STATUS_FILE" >"$tmp/status.next"
mv "$tmp/status.next" "$OMARCHY_BOOTC_TEST_STATUS_FILE"
if bash "$AVAILABLE" >"$tmp/available.out" 2>"$tmp/available.err"; then fail 'availability reported an update for the booted digest'; fi
[[ ! -s "$tmp/available.err" ]] || fail 'no-update result was treated as a resolver failure'
grep -Fxq 'Omarchy image is up to date' "$tmp/available.out" ||
    fail 'availability helper did not report the no-update result'
printf 'PASS: composefs updater transactions and availability\n'
