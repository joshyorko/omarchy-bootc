#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/custom/first-boot/omarchy-adopt-existing-user.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/bin" "$tmp/home/alice/.config/hypr" \
    "$tmp/home/alice/.gemini/skills/custom-gemini" \
    "$tmp/home/alice/.hermes/skills/custom-hermes" \
    "$tmp/home/alice/.hermes/profiles/work/skills/work-skill" \
    "$tmp/state"
printf 'baseline\n' >"$tmp/home/alice/.config/hypr/settings.conf"
printf 'user-gemini\n' >"$tmp/home/alice/.gemini/skills/custom-gemini/SKILL.md"
printf 'user-hermes\n' >"$tmp/home/alice/.hermes/skills/custom-hermes/SKILL.md"
printf 'user-work\n' >"$tmp/home/alice/.hermes/profiles/work/skills/work-skill/SKILL.md"
: >"$tmp/passwd-db"
: >"$tmp/group-db"
: >"$tmp/auth"
: >"$tmp/chpasswd-count"
: >"$tmp/ask-count"
: >"$tmp/provision-count"
: >"$tmp/chown-log"

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
cat >"$tmp/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CHOWN_LOG"
exit 0
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
printf 'required-hyprland-lua\n' >"$HOME/.config/hypr/hyprland.lua"
# Create a previously-absent protected path on the crashing attempt; retry must
# keep the frozen absent baseline instead of backing this up.
printf 'crashed-gitconfig-%s\n' "$count" >"$HOME/.gitconfig"
mkdir -p "$HOME/.gemini/skills/omarchy" "$HOME/.hermes/skills/omarchy" "$HOME/.hermes/profiles/work/skills/omarchy"
printf 'official-skill\n' >"$HOME/.gemini/skills/omarchy/SKILL.md"
printf 'official-skill\n' >"$HOME/.hermes/skills/omarchy/SKILL.md"
printf 'official-skill\n' >"$HOME/.hermes/profiles/work/skills/omarchy/SKILL.md"
(( count > 1 ))
EOF
chmod +x "$tmp/bin"/* "$tmp/provision"

export PATH="$tmp/bin:$PATH" FAKE_PASSWD_DB="$tmp/passwd-db" FAKE_GROUP_DB="$tmp/group-db"
export FAKE_HOME="$tmp/home/alice" FAKE_AUTH="$tmp/auth" FAKE_ASK_COUNT="$tmp/ask-count"
export FAKE_CHPASSWD_COUNT="$tmp/chpasswd-count"
export FAKE_PROVISION_COUNT="$tmp/provision-count" FAKE_CHOWN_LOG="$tmp/chown-log"
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
[[ ! -e "$run_root/.gitconfig" ]] || fail 'absent path appeared in backup before retry'

run_adoption || fail 'retry after provisioning crash did not complete'
grep -Fxq 'status=complete' "$tmp/state/state.env" || fail 'retry did not mark adoption complete'
[[ "$(grep -c '^alice:' "$tmp/passwd-db")" == 1 ]] || fail 'retry duplicated the account'
grep -Fxq 'baseline' "$tmp/home/alice/.config/hypr/settings.conf" || fail 'retry reseeded or lost the baseline settings'
# P1-09: required missing desktop files generated by provisioning must be seeded.
grep -Fxq 'required-hyprland-lua' "$tmp/home/alice/.config/hypr/hyprland.lua" || fail 'required missing hyprland.lua was not seeded'
# P1-09: Gemini and Hermes skills (including profiles) must be preserved alongside seeded official skills.
grep -Fxq 'user-gemini' "$tmp/home/alice/.gemini/skills/custom-gemini/SKILL.md" || fail 'existing Gemini skill was lost'
grep -Fxq 'official-skill' "$tmp/home/alice/.gemini/skills/omarchy/SKILL.md" || fail 'official Gemini skill was not seeded'
grep -Fxq 'user-hermes' "$tmp/home/alice/.hermes/skills/custom-hermes/SKILL.md" || fail 'existing Hermes skill was lost'
grep -Fxq 'official-skill' "$tmp/home/alice/.hermes/skills/omarchy/SKILL.md" || fail 'official Hermes skill was not seeded'
grep -Fxq 'user-work' "$tmp/home/alice/.hermes/profiles/work/skills/work-skill/SKILL.md" || fail 'existing Hermes profile skill was lost'
grep -Fxq 'official-skill' "$tmp/home/alice/.hermes/profiles/work/skills/omarchy/SKILL.md" || fail 'official Hermes profile skill was not seeded'
# P1-08: previously absent .gitconfig created during the crashed attempt must NOT be promoted into backup on retry.
[[ ! -e "$run_root/.gitconfig" ]] || fail 'retry contaminated frozen absent baseline with crashed provisioning output'
grep -Fxq 'crashed-gitconfig-2' "$tmp/home/alice/.gitconfig" || fail 'retry overwrote newly provisioned file from absent baseline'
[[ -f "$(dirname "$run_root")/rollback/after/.config/hypr/settings.conf" ]] || fail 'retry did not retain generated settings for recovery'

# P1-07: symlinked parent directory inside home must be refused without mutating outside target.
mkdir -p "$tmp/escape-target" "$tmp/sym-home/bob" "$tmp/sym-state"
ln -s "$tmp/escape-target" "$tmp/sym-home/bob/.config"
if env OMARCHY_ADOPTION_HOME_ROOT="$tmp/sym-home" OMARCHY_ADOPTION_STATE_ROOT="$tmp/sym-state" \
    OMARCHY_INSTALLER_ORIGIN_FILE="$tmp/no-installer-origin" OMARCHY_ADOPTION_USER_FILE="$tmp/no-selection" \
    OMARCHY_ADOPTION_PROVISION_BIN="$tmp/provision" bash "$SCRIPT" >"$tmp/sym.out" 2>&1; then
    fail 'symlinked parent directory inside home was accepted'
fi
grep -Fq 'Refusing symlinked parent directory inside home' "$tmp/sym.out" || fail 'wrong error on symlinked home parent'

printf 'PASS: adoption transaction resumes failures, freezes baseline, preserves Gemini/Hermes skills, seeds missing desktop files, and confines home mutations\n'
