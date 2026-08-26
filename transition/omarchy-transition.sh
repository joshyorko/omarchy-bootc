#!/usr/bin/env bash
set -euo pipefail

# State-aware transition helper.  It sits above bootc: it identifies and
# records the source system, captures only non-secret identity/config metadata,
# creates a bounded backup before switching, and leaves target-side user
# adoption to omarchy-adopt-existing-user.sh.

ROOT="${OMARCHY_TRANSITION_ROOT:-/}"
STATE_ROOT="${OMARCHY_TRANSITION_STATE_ROOT:-${ROOT}/var/lib/omarchy-bootc/transitions}"
STATE_FILE="${STATE_ROOT}/state.env"
BOOTC_BIN="${OMARCHY_TRANSITION_BOOTC_BIN:-bootc}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

root_path() {
    local path="$1"
    if [[ "$ROOT" == "/" ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "${ROOT%/}" "${path#/}"
    fi
}

read_os_release_field() {
    local field="$1" file
    file="$(root_path /usr/lib/os-release)"
    [[ -f "$file" ]] || file="$(root_path /etc/os-release)"
    [[ -f "$file" ]] || return 0
    sed -n "s/^${field}=//p" "$file" | head -n 1 | tr -d '"'
}

source_profile() {
    local id variant name
    id="$(read_os_release_field ID)"
    variant="$(read_os_release_field VARIANT_ID)"
    name="$(read_os_release_field NAME)"
    case "${id}:${variant}:${name}" in
        bluefin:*:*|*:bluefin:*|*:Bluefin*) printf 'bluefin\n' ;;
        dakota:*:*|*:dakota:*|*:Dakota*) printf 'dakota\n' ;;
        omarchy:*:*|*:omarchy:*|*:Omarchy*) printf 'omarchy\n' ;;
        arch:*:*|*:omarchy-bootc:*)
            [[ -e "$(root_path /usr/share/omarchy)" ]] && printf 'omarchy\n' && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

bootc_available() {
    if [[ "$ROOT" == "/" ]]; then
        command -v "$BOOTC_BIN" >/dev/null 2>&1
    else
        [[ -x "$(root_path /usr/bin/bootc)" || -x "$(root_path /usr/sbin/bootc)" ]]
    fi
}

write_state() {
    local stage="$1" profile="$2" target="$3" transition_dir="$4" backup_dir="$5"
    local tmp="${STATE_FILE}.tmp.$$"
    install -d -m 0700 "$STATE_ROOT"
    {
        printf 'stage=%s\n' "$stage"
        printf 'source_profile=%s\n' "$profile"
        printf 'target_ref=%s\n' "$target"
        printf 'transition_dir=%s\n' "$transition_dir"
        printf 'backup_dir=%s\n' "$backup_dir"
    } >"$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

state_value() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n "s/^${key}=//p" "$STATE_FILE" | head -n 1
}

require_bootc_source() {
    local profile
    profile="$(source_profile 2>/dev/null || true)"
    [[ -n "$profile" ]] || die 'unsupported source profile; refusing an arbitrary cross-distro switch'
    bootc_available || die 'bootc is not available on the current source system'
    printf '%s\n' "$profile"
}

home_directories() {
    local home_root
    home_root="$(root_path /var/home)"
    [[ -d "$home_root" ]] || return 0
    find "$home_root" -mindepth 1 -maxdepth 1 -type d \
        ! -name lost+found ! -name root ! -name nobody -printf '%f\n' | sort
}

capture_state() {
    local profile transition_id transition_dir passwd_file group_file home_root
    profile="$(require_bootc_source)"
    transition_id="$(date +%Y%m%d-%H%M%S)-$$"
    transition_dir="${STATE_ROOT}/${transition_id}"
    mkdir -p "${transition_dir}/source" "${transition_dir}/homes"
    chmod 0700 "$transition_dir" "${transition_dir}/source" "${transition_dir}/homes"

    passwd_file="$(root_path /etc/passwd)"
    group_file="$(root_path /etc/group)"
    # Identity-only snapshots intentionally omit passwd/shadow fields and all
    # other credentials.  Password hashes never enter transition state.
    if [[ -f "$passwd_file" ]]; then
        awk -F: '{print $1 ":" $3 ":" $4 ":" $6 ":" $7}' \
            "$passwd_file" >"${transition_dir}/source/users"
    else
        : >"${transition_dir}/source/users"
    fi
    if [[ -f "$group_file" ]]; then
        awk -F: '{print $1 ":" $3}' "$group_file" >"${transition_dir}/source/groups"
    else
        : >"${transition_dir}/source/groups"
    fi

    home_root="$(root_path /var/home)"
    while IFS= read -r user; do
        [[ -n "$user" ]] || continue
        stat -c '%n %u %g' "${home_root}/${user}" \
            >>"${transition_dir}/source/homes"
    done < <(home_directories)

    write_state captured "$profile" "" "$transition_dir" ""
    printf 'source_profile=%s\nstatus=captured\ntransition_dir=%s\n' \
        "$profile" "$transition_dir"
}

backup_state() {
    local stage profile target transition_dir backup_dir home_root user relative source destination
    stage="$(state_value stage)"
    [[ "$stage" == captured ]] || die 'refusing backup before state capture'
    profile="$(state_value source_profile)"
    target="$(state_value target_ref)"
    transition_dir="$(state_value transition_dir)"
    backup_dir="${transition_dir}/backup"
    mkdir -p "$backup_dir"
    chmod 0700 "$backup_dir"

    home_root="$(root_path /var/home)"
    while IFS= read -r user; do
        [[ -n "$user" ]] || continue
        while IFS= read -r relative; do
            source="${home_root}/${user}/${relative}"
            path_exists=0
            [[ -e "$source" || -L "$source" ]] && path_exists=1
            (( path_exists == 1 )) || continue
            destination="${backup_dir}/homes/${user}/${relative}"
            install -d -m 0700 "$(dirname "$destination")"
            cp -a -- "$source" "$destination"
        done <<'EOF'
.config/hypr
.config/omarchy
.config/gtk-3.0/bookmarks
.config/user-dirs.dirs
.config/user-dirs.locale
.config/mimeapps.list
.agents/skills
.claude/skills
.codex/skills
.pi/agent/skills
.XCompose
.gitconfig
Work/.mise.toml
EOF
    done < <(home_directories)

    write_state backed-up "$profile" "$target" "$transition_dir" "$backup_dir"
    printf 'status=backed-up\nbackup_dir=%s\n' "$backup_dir"
}

apply_switch() {
    local target="" confirm=0 stage profile transition_dir backup_dir
    while (($#)); do
        case "$1" in
            --confirm) confirm=1 ;;
            --) shift; break ;;
            -*) die "unknown apply option: $1" ;;
            *) [[ -z "$target" ]] || die 'apply accepts one target image reference'; target="$1" ;;
        esac
        shift
    done
    [[ -n "$target" ]] || die 'apply requires a target image reference'
    (( confirm == 1 )) || die 'refusing to switch without explicit --confirm'
    [[ "$ROOT" == "/" ]] || die 'apply must run on the live source system'
    stage="$(state_value stage)"
    [[ "$stage" == backed-up ]] || die 'refusing to switch before state capture and backup'
    profile="$(state_value source_profile)"
    transition_dir="$(state_value transition_dir)"
    backup_dir="$(state_value backup_dir)"
    # The transition operation itself remains the upstream bootc switch.
    "$BOOTC_BIN" switch "$target"
    write_state switched "$profile" "$target" "$transition_dir" "$backup_dir"
    printf 'status=switched\nreboot_required=yes\ntarget_ref=%s\n' "$target"
}

recover_transition() {
    local confirm=0 stage
    while (($#)); do
        case "$1" in
            --confirm) confirm=1 ;;
            *) die "unknown recover option: $1" ;;
        esac
        shift
    done
    (( confirm == 1 )) || die 'refusing recovery without explicit --confirm'
    stage="$(state_value stage)"
    [[ "$stage" == switched || "$stage" == adopted ]] || die 'no switched transition is ready for recovery'
    if [[ "$ROOT" == "/" && -x /usr/bin/omarchy-adoption-rollback ]]; then
        /usr/bin/omarchy-adoption-rollback
    else
        die 'target-side omarchy-adoption-rollback is unavailable; recover from the target system'
    fi
    write_state recovered "$(state_value source_profile)" "$(state_value target_ref)" \
        "$(state_value transition_dir)" "$(state_value backup_dir)"
    printf 'status=recovered\nbootc_rollback_is_separate=yes\n'
}

preflight() {
    local target="$1" profile
    [[ -n "$target" ]] || die 'preflight requires a target image reference'
    profile="$(require_bootc_source)"
    [[ -d "$(root_path /var/home)" ]] || die '/var/home is not available for state-aware transition'
    printf 'source_profile=%s\ntarget_ref=%s\nstatus=ready\n' "$profile" "$target"
}

usage() {
    cat <<'EOF'
Usage:
  omarchy-transition preflight <target-image>
  omarchy-transition capture-state
  omarchy-transition backup
  omarchy-transition apply --confirm <target-image>
  omarchy-transition recover --confirm

Supported source profiles are Bluefin, Dakota, and existing Omarchy bootc.
Unknown systems are refused rather than guessed.  Recovery restores the
target-side adoption backup independently of bootc rollback.
EOF
}

command_name="${1:-}"
shift || true
case "$command_name" in
    preflight) (($# == 1)) || die 'preflight accepts exactly one target image'; preflight "$1" ;;
    capture-state) (($# == 0)) || die 'capture-state accepts no arguments'; capture_state ;;
    backup) (($# == 0)) || die 'backup accepts no arguments'; backup_state ;;
    apply) apply_switch "$@" ;;
    recover) recover_transition "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
