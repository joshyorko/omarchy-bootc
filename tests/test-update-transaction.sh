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
    'upgrade --download-only')
        [[ -f "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" ]] || exit 10
        exit_code="${UPGRADE_RC:-0}"
        [[ "$exit_code" == 0 ]] || exit "$exit_code"
        jq --arg digest "$STAGE_DIGEST" '.status.staged={image:{imageDigest:$digest},downloadOnly:true}' \
            "$OMARCHY_BOOTC_TEST_STATUS_FILE" >"${OMARCHY_BOOTC_TEST_STATUS_FILE}.next"
        mv "${OMARCHY_BOOTC_TEST_STATUS_FILE}.next" "$OMARCHY_BOOTC_TEST_STATUS_FILE"
        ;;
    'upgrade --from-downloaded')
        [[ "$(jq -r '.status.staged.downloadOnly' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == true ]] || exit 11
        jq '.status.staged.downloadOnly=false' \
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
        [[ "$2" == --raw && "$3" == "docker://${TEST_TRACKING_REF:-ghcr.io/example/os:testing}" ]] || exit 1
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
if (( EUID != 0 )); then
cat >"$tmp/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c && "${2:-}" == '%u:%a' && "${3:-}" == "${OMARCHY_BOOTC_TEST_TRANSACTION_MARKER:-}" ]]; then
    mode="$(/usr/bin/stat -c '%a' "$3")"
    printf '0:%s\n' "$mode"
else
    exec /usr/bin/stat "$@"
fi
EOF
chmod +x "$tmp/bin/stat"
fi
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
export OMARCHY_BOOTC_TEST_COSIGN_BIN="$tmp/no-cosign"
# SUDO_USER is unrelated to these isolated per-test directories.
unset SUDO_USER
make_test_script() {
    local input="$1" output="$2"
# These sed expressions are literal replacement source, not shell expansions.
# shellcheck disable=SC2016
    sed \
        -e "s|^source /usr/lib/omarchy-bootc/update-common.sh$|source \"${ROOT_DIR}/custom/bootc/omarchy-bootc-common.sh\"|" \
        -e 's|^export OMARCHY_BOOTC_BIN=/usr/bin/bootc$|export OMARCHY_BOOTC_BIN="${OMARCHY_BOOTC_TEST_BIN:?}"|' \
        -e 's|^readonly COSIGN_BIN=/usr/bin/cosign$|readonly COSIGN_BIN="${OMARCHY_BOOTC_TEST_COSIGN_BIN:?}"|' \
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
    export TEST_TRACKING_REF=ghcr.io/example/os:testing
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

setup_case composefs
bash "$SCRIPT" -y >"$tmp/update.out"
[[ "$(jq -r '.status.staged.image.imageDigest' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == "$b" ]] || fail 'ordinary null-cachedUpdate path did not stage B'
[[ "$(jq -r '.status.staged.downloadOnly' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == false ]] || fail 'verified stage was not unlocked'
[[ "$(cat "$BOOTC_LOG")" == $'upgrade --check\nupgrade --download-only\nupgrade --from-downloaded' ]] || fail 'ordinary path did not check, download-only, verify, then unlock'
grep -Fxq "expected_digest=$b" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" || fail 'root intent did not retain exact resolved digest'
grep -Fxq "tracking_ref=ghcr.io/example/os:testing" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" || fail 'root intent did not retain intended channel'
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
[[ "$(stat -c '%u:%a' "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER")" == "0:600" ]] ||
    fail 'root transaction marker has the wrong owner or mode'
[[ "$(stat -c '%u:%a' "$OMARCHY_BOOTC_TEST_STATE_HOME/omarchy-bootc/pending-update")" == "$(id -u):600" ]] ||
    fail 'user transaction marker has the wrong owner or mode'
unset SUDO_USER
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

setup_case upgrade-failure
export UPGRADE_RC=1
if bash "$SCRIPT" -y; then fail 'failed bootc staging was accepted'; fi
[[ "$(jq -r '.status.staged' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == null ]] || fail 'failed upgrade produced a stage'
grep -Fxq "expected_digest=$b" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" || fail 'failed staging lost the exact intent'

# A moving tag must not unlock an unexpected stage for reboot or leave markers behind.
setup_case tag-moved
export STAGE_DIGEST="$c"
if bash "$SCRIPT" -y >"$tmp/tag-moved.out" 2>"$tmp/tag-moved.err"; then fail 'stage differing from resolved B was accepted'; fi
[[ ! -e "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" ]] || fail 'tag move left root transaction marker behind'
[[ ! -e "$OMARCHY_BOOTC_TEST_STATE_HOME/omarchy-bootc/pending-update" ]] || fail 'tag move left user transaction marker behind'
[[ "$(jq -r '.status.staged.image.imageDigest' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == "$c" ]] || fail 'tag-move fixture did not record C'
[[ "$(jq -r '.status.staged.downloadOnly' "$OMARCHY_BOOTC_TEST_STATUS_FILE")" == true ]] || fail 'unexpected stage C was unlocked for reboot'
if grep -Fxq 'upgrade --from-downloaded' "$BOOTC_LOG"; then fail 'tag move unlocked unexpected stage C'; fi

setup_case already-staged
jq --arg b "$b" '.status.staged={image:{imageDigest:$b},downloadOnly:false}' "$OMARCHY_BOOTC_TEST_STATUS_FILE" >"$tmp/status.next"
mv "$tmp/status.next" "$OMARCHY_BOOTC_TEST_STATUS_FILE"
export RESOLVER_RC=1
bash "$SCRIPT" -y
[[ "$(cat "$BOOTC_LOG")" == 'upgrade --check' ]] || fail 'already-staged path staged again'
grep -Fxq "expected_digest=$b" "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" || fail 'already-staged intent lost B'
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

official_case() {
    setup_case "$1"
    export TEST_TRACKING_REF="${2:-ghcr.io/joshyorko/omarchy-bootc:testing}"
    jq --arg ref "$TEST_TRACKING_REF" '.spec.image.image=$ref | .status.booted.image.image.image=$ref' \
        "$OMARCHY_BOOTC_TEST_STATUS_FILE" >"$tmp/status.next"
    mv "$tmp/status.next" "$OMARCHY_BOOTC_TEST_STATUS_FILE"
}
official_case missing-verifier
# A PATH impostor must not satisfy the image-owned verifier requirement.
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/cosign"
chmod +x "$tmp/bin/cosign"
if bash "$SCRIPT" -y >"$tmp/missing-verifier.out" 2>&1; then fail 'missing image-owned Cosign was accepted'; fi
grep -Fq 'requires image-owned Cosign' "$tmp/missing-verifier.out" || fail 'missing verifier diagnostic absent'
assert_unstaged
official_case missing-verifier-pinned "ghcr.io/joshyorko/omarchy-bootc@$b"
if bash "$SCRIPT" -y >"$tmp/missing-pinned.out" 2>&1; then fail 'pinned official ref bypassed missing verifier'; fi
assert_unstaged
official_case missing-verifier-case 'GHCR.IO/JOSHYORKO/OMARCHY-BOOTC:testing'
if bash "$SCRIPT" -y >"$tmp/missing-case.out" 2>&1; then fail 'official ref case variant bypassed missing verifier'; fi
assert_unstaged

export OMARCHY_BOOTC_TEST_COSIGN_BIN="$tmp/verifier"
export FAKE_COSIGN_LOG="$tmp/cosign.log"
cat >"$tmp/verifier" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$FAKE_COSIGN_LOG"
[[ $# == 6 && $1 == verify && $2 == --certificate-identity && $3 == 'https://github.com/joshyorko/omarchy-bootc/.github/workflows/build.yml@refs/heads/main' && $4 == --certificate-oidc-issuer && $5 == 'https://token.actions.githubusercontent.com' && $6 == "ghcr.io/joshyorko/omarchy-bootc@$STAGE_DIGEST" ]] || exit 3
exit "${COSIGN_RC:-0}"
EOF
official_case nonexecutable-verifier
if bash "$SCRIPT" -y >"$tmp/nonexecutable.out" 2>&1; then fail 'non-executable Cosign was accepted'; fi
assert_unstaged
chmod +x "$tmp/verifier"
official_case invalid-signature
export COSIGN_RC=1
if bash "$SCRIPT" -y >"$tmp/invalid-signature.out" 2>&1; then fail 'failed signature verification was accepted'; fi
[[ $(jq -r '.status.staged.downloadOnly' "$OMARCHY_BOOTC_TEST_STATUS_FILE") == true ]] || fail 'unverified stage was unlocked'
if grep -Fxq 'upgrade --from-downloaded' "$BOOTC_LOG"; then fail 'failed verifier reached unlock'; fi
[[ ! -e "$OMARCHY_BOOTC_TEST_TRANSACTION_MARKER" ]] || fail 'signature failure retained certification intent'
official_case valid-signature
export COSIGN_RC=0
bash "$SCRIPT" -y >"$tmp/valid-signature.out"
[[ $(jq -r '.status.staged.downloadOnly' "$OMARCHY_BOOTC_TEST_STATUS_FILE") == false ]] || fail 'valid signature did not unlock stage'
grep -Fxq "ghcr.io/joshyorko/omarchy-bootc@$b" "$FAKE_COSIGN_LOG" || fail 'verifier did not bind the exact staged digest'
official_case already-unlocked-invalid
jq --arg b "$b" '.status.staged={image:{imageDigest:$b},downloadOnly:false}' "$OMARCHY_BOOTC_TEST_STATUS_FILE" >"$tmp/status.next"
mv "$tmp/status.next" "$OMARCHY_BOOTC_TEST_STATUS_FILE"
export COSIGN_RC=1 RESOLVER_RC=1
if bash "$SCRIPT" -y >"$tmp/already-unlocked.out" 2>&1; then fail 'already-unlocked official stage bypassed verification'; fi
[[ $(cat "$BOOTC_LOG") == 'upgrade --check' ]] || fail 'already-unlocked path mutated stage'
printf 'PASS: updater transactions/availability and mandatory image-owned signature verification (negative/resume controls)\n'
