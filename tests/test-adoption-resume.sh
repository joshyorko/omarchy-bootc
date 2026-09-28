#!/usr/bin/env bash
set -euo pipefail

(( EUID == 0 )) || { echo 'SKIP: adoption lifecycle fixture requires root'; exit 0; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/custom/first-boot/omarchy-adopt-existing-user.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/bin" "$tmp/home/alice/.config/hypr" "$tmp/state"
printf 'baseline\n' >"$tmp/home/alice/.config/hypr/settings.conf"
: >"$tmp/passwd-db"
: >"$tmp/group-db"
: >"$tmp/auth"
: >"$tmp/chpasswd-count"
: >"$tmp/ask-count"
: >"$tmp/provision-count"

cat >"$tmp/bin/getent" <<'EOF'
#!/usr/bin/env bash
kind="$1"; key="$2"
case "$kind" in
  passwd) awk -F: -v key="$key" '$1 == key || $3 == key {print; found=1} END {exit !found}' "$FAKE_PASSWD_DB" ;;
  group) awk -F: -v key="$key" '$1 == key || $3 == key {print; found=1} END {exit !found}' "$FAKE_GROUP_DB" ;;
  *) exit 1 ;;
esac
EOF
cat >"$tmp/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -c && ( ${2:-} == %u || ${2:-} == %g ) ]]; then printf '1000\n'; else exec /usr/bin/stat "$@"; fi
EOF
cat >"$tmp/bin/groupadd" <<'EOF'
#!/usr/bin/env bash
printf 'alice:x:%s:\n' "$2" >>"$FAKE_GROUP_DB"
EOF
cat >"$tmp/bin/useradd" <<'EOF'
#!/usr/bin/env bash
printf 'alice:x:1000:1000:Alice:%s:/bin/bash\n' "$FAKE_HOME" >>"$FAKE_PASSWD_DB"
EOF
cat >"$tmp/bin/usermod" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/passwd" <<'EOF'
#!/usr/bin/env bash
printf 'alice %s 2026-01-01 0 99999 7 -1\n' "$(cat "$FAKE_AUTH")"
EOF
cat >"$tmp/bin/systemd-ask-password" <<'EOF'
#!/usr/bin/env bash
count="$(cat "$FAKE_ASK_COUNT")"
count=$((count + 1)); printf '%s\n' "$count" >"$FAKE_ASK_COUNT"
if (( count == 1 )); then exit 1; fi
printf 'fixture-password\n'
EOF
cat >"$tmp/bin/chpasswd" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
count="$(cat "$FAKE_CHPASSWD_COUNT")"
count=$((count + 1)); printf '%s\n' "$count" >"$FAKE_CHPASSWD_COUNT"
if (( count == 1 )); then exit 0; fi
printf 'P\n' >"$FAKE_AUTH"
EOF
cat >"$tmp/bin/runuser" <<'EOF'
#!/usr/bin/env bash
shift 3
exec "$@"
EOF
cat >"$tmp/provision" <<'EOF'
#!/usr/bin/env bash
count="$(cat "$FAKE_PROVISION_COUNT")"
count=$((count + 1)); printf '%s\n' "$count" >"$FAKE_PROVISION_COUNT"
printf 'generated-%s\n' "$count" >"$HOME/.config/hypr/settings.conf"
(( count > 1 ))
EOF
chmod +x "$tmp/bin"/* "$tmp/provision"

export PATH="$tmp/bin:$PATH" FAKE_PASSWD_DB="$tmp/passwd-db" FAKE_GROUP_DB="$tmp/group-db"
export FAKE_HOME="$tmp/home/alice" FAKE_AUTH="$tmp/auth" FAKE_ASK_COUNT="$tmp/ask-count"
export FAKE_CHPASSWD_COUNT="$tmp/chpasswd-count"
export FAKE_PROVISION_COUNT="$tmp/provision-count"
run_adoption() {
    env OMARCHY_ADOPTION_HOME_ROOT="$tmp/home" OMARCHY_ADOPTION_STATE_ROOT="$tmp/state" \
        OMARCHY_INSTALLER_ORIGIN_FILE="$tmp/no-installer-origin" OMARCHY_ADOPTION_USER_FILE="$tmp/no-selection" \
        OMARCHY_ADOPTION_PROVISION_BIN="$tmp/provision" bash "$SCRIPT"
}

if run_adoption; then fail 'password prompt failure was reported as successful adoption'; fi
grep -Fxq 'status=needs-password' "$tmp/state/state.env" || fail 'password failure state was not persisted'
[[ "$(grep -c '^alice:' "$tmp/passwd-db")" == 1 ]] || fail 'account creation was not recorded exactly once'

if run_adoption; then fail 'locked account was reported as complete'; fi
grep -Fxq 'status=needs-password' "$tmp/state/state.env" || fail 'locked account did not remain pending'
[[ ! -s "$tmp/provision-count" ]] || fail 'locked account reached upstream provisioning'

if run_adoption; then fail 'first upstream provisioning failure was reported as success'; fi
grep -Fxq 'status=failed' "$tmp/state/state.env" || fail 'provisioning failure state was not persisted'
run_root="$(sed -n 's#^backup_root=##p' "$tmp/state/state.env")"
grep -Fxq 'baseline' "$run_root/.config/hypr/settings.conf" || fail 'original backup was not recorded'

run_adoption || fail 'retry after provisioning crash did not complete'
grep -Fxq 'status=complete' "$tmp/state/state.env" || fail 'retry did not mark adoption complete'
[[ "$(grep -c '^alice:' "$tmp/passwd-db")" == 1 ]] || fail 'retry duplicated the account'
grep -Fxq 'baseline' "$tmp/home/alice/.config/hypr/settings.conf" || fail 'retry reseeded or lost the baseline settings'
[[ -f "$(dirname "$run_root")/rollback/after/.config/hypr/settings.conf" ]] || fail 'retry did not retain generated settings for recovery'

printf 'PASS: adoption transaction resumes password and provisioning failures\n'
