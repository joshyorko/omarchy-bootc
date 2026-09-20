#!/usr/bin/env bash
set -euo pipefail

# Source-side safety boundary for a Dakota/Bluefin -> Omarchy bootc switch.
# This helper never mutates the source until preflight, capture, and backup have
# completed. The mutable stream ref is persisted separately from its preflight
# digest so future bootc upgrades continue to follow :testing.

ROOT="${OMARCHY_TRANSITION_ROOT:-/}"
STATE_ROOT="${OMARCHY_TRANSITION_STATE_ROOT:-${ROOT}/var/lib/omarchy-bootc/transitions}"
STATE_FILE="${STATE_ROOT}/state.env"
PREFLIGHT_FILE="${STATE_ROOT}/preflight.env"
BOOTC_BIN="${OMARCHY_TRANSITION_BOOTC_BIN:-bootc}"
RESOLVER="${OMARCHY_TRANSITION_RESOLVER:-}"
STATUS_FILE="${OMARCHY_TRANSITION_STATUS_FILE:-}"

DIE() {
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

run_bootc() {
    if [[ "$ROOT" == "/" ]]; then
        "$BOOTC_BIN" "$@"
    else
        local rooted
        rooted="$(root_path /usr/bin/bootc)"
        [[ -x "$rooted" ]] || rooted="$(root_path /usr/sbin/bootc)"
        [[ -x "$rooted" ]] || return 127
        "$rooted" "$@"
    fi
}

read_os_release_field() {
    local field="$1" file value
    file="$(root_path /usr/lib/os-release)"
    [[ -f "$file" ]] || file="$(root_path /etc/os-release)"
    [[ -f "$file" ]] || return 0
    value="$(sed -n "s/^${field}=//p" "$file" | sed -n '1p')"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s\n' "$value"
}

status_json() {
    if [[ -n "$STATUS_FILE" ]]; then
        cat "$STATUS_FILE"
    else
        run_bootc status --format=json
    fi
}

# Set SOURCE_PROFILE/SOURCE_SIGNAL/SOURCE_VALUE from strongest available
# structured evidence. A familiar NAME alone is intentionally never enough.
detect_source() {
    local status="" reference="" image_info="" id="" variant="" name=""
    SOURCE_PROFILE=""
    SOURCE_SIGNAL=""
    SOURCE_VALUE=""

    if status="$(status_json 2>/dev/null || true)"; then
        reference="$(printf '%s\n' "$status" | grep -Eio '([[:alnum:]._-]+/)?[[:alnum:]._-]+(:[^"[:space:]]+|@sha256:[[:xdigit:]]{64})' | grep -Eim1 '(bluefin|dakota|omarchy)' || true)"
        case "${reference,,}" in
            *dakota*)
                SOURCE_PROFILE=dakota
                SOURCE_SIGNAL=bootc-status
                SOURCE_VALUE="$reference"
                ;;
            *bluefin*)
                SOURCE_PROFILE=bluefin
                SOURCE_SIGNAL=bootc-status
                SOURCE_VALUE="$reference"
                ;;
            *omarchy*)
                SOURCE_PROFILE=omarchy
                SOURCE_SIGNAL=bootc-status
                SOURCE_VALUE="$reference"
                ;;
        esac
    fi

    if [[ -z "$SOURCE_PROFILE" ]]; then
        image_info="$(root_path /usr/share/ublue-os/image-info.json)"
        if [[ -f "$image_info" ]]; then
            reference="$(tr '\n' ' ' <"$image_info" | grep -Eio '(bluefin-dakota|dakota|bluefin|omarchy)[[:alnum:]._-]*' | head -n 1 || true)"
            case "${reference,,}" in
                *dakota*) SOURCE_PROFILE=dakota; SOURCE_SIGNAL=image-info; SOURCE_VALUE="$reference" ;;
                *bluefin*) SOURCE_PROFILE=bluefin; SOURCE_SIGNAL=image-info; SOURCE_VALUE="$reference" ;;
                *omarchy*) SOURCE_PROFILE=omarchy; SOURCE_SIGNAL=image-info; SOURCE_VALUE="$reference" ;;
            esac
        fi
    fi

    if [[ -z "$SOURCE_PROFILE" ]]; then
        id="$(read_os_release_field ID)"
        variant="$(read_os_release_field VARIANT_ID)"
        name="$(read_os_release_field NAME)"
        case "${id,,}:${variant,,}" in
            bluefin-dakota:*|dakota:*) SOURCE_PROFILE=dakota; SOURCE_SIGNAL=os-release; SOURCE_VALUE="ID=${id};VARIANT_ID=${variant}" ;;
            bluefin:*|*:bluefin) SOURCE_PROFILE=bluefin; SOURCE_SIGNAL=os-release; SOURCE_VALUE="ID=${id};VARIANT_ID=${variant}" ;;
            omarchy:*|*:omarchy) SOURCE_PROFILE=omarchy; SOURCE_SIGNAL=os-release; SOURCE_VALUE="ID=${id};VARIANT_ID=${variant}" ;;
            arch:*)
                if [[ -d "$(root_path /usr/share/omarchy)" ]]; then
                    SOURCE_PROFILE=omarchy
                    SOURCE_SIGNAL=os-release+omarchy-payload
                    SOURCE_VALUE="ID=${id};NAME=${name}"
                fi
                ;;
        esac
    fi

    [[ -n "$SOURCE_PROFILE" ]] || return 1
}

json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1" | tr -d '\n'
}

inspect_source() {
    detect_source || DIE 'unsupported source profile; refusing an arbitrary cross-distro switch'
    printf '{"profile":"%s","signal":"%s","evidence":[{"source":"%s","value":"%s"}]}\n' \
        "$(json_escape "$SOURCE_PROFILE")" \
        "$(json_escape "$SOURCE_SIGNAL")" \
        "$(json_escape "$SOURCE_SIGNAL")" \
        "$(json_escape "$SOURCE_VALUE")"
}

require_source() {
    detect_source || DIE 'unsupported source profile; refusing an arbitrary cross-distro switch'
    if [[ "$ROOT" == "/" ]]; then
        command -v "$BOOTC_BIN" >/dev/null 2>&1 || DIE 'bootc is not available on the current source system'
    else
        [[ -x "$(root_path /usr/bin/bootc)" || -x "$(root_path /usr/sbin/bootc)" ]] ||
            DIE 'bootc is not available on the current source fixture'
    fi
    printf '%s\n' "$SOURCE_PROFILE"
}

require_tracking_ref() {
    local ref="$1"
    [[ "$ref" != *@sha256:* && "$ref" =~ ^[^/@[:space:]]+/.+:[^/@[:space:]]+$ ]] ||
        DIE 'target must be a mutable registry tracking ref such as ghcr.io/joshyorko/omarchy-bootc:testing'
}

resolve_digest() {
    local ref="$1" digest=""
    require_tracking_ref "$ref"
    if [[ -n "$RESOLVER" ]]; then
        digest="$($RESOLVER "$ref")"
    elif command -v skopeo >/dev/null 2>&1; then
        digest="$(skopeo inspect --format '{{.Digest}}' "docker://${ref}" 2>/dev/null || true)"
    elif command -v podman >/dev/null 2>&1; then
        digest="$(podman image inspect --format '{{index .RepoDigests 0}}' "$ref" 2>/dev/null || true)"
        digest="${digest##*@}"
    else
        DIE 'cannot resolve target tracking ref: install skopeo/podman or provide OMARCHY_TRANSITION_RESOLVER'
    fi
    digest="${digest##*@}"
    [[ "$digest" =~ ^sha256:[[:xdigit:]]{64}$ ]] || DIE "resolver did not return an immutable digest for ${ref}"
    printf '%s\n' "$digest"
}

write_state() {
    local stage="$1" profile="$2" tracking="$3" digest="$4" transition_dir="$5" backup_dir="$6"
    local tmp="${STATE_FILE}.tmp.$$"
    install -d -m 0700 "$STATE_ROOT"
    {
        printf 'stage=%s\n' "$stage"
        printf 'source_profile=%s\n' "$profile"
        printf 'target_tracking_ref=%s\n' "$tracking"
        printf 'target_resolved_digest=%s\n' "$digest"
        printf 'transition_dir=%s\n' "$transition_dir"
        printf 'backup_dir=%s\n' "$backup_dir"
    } >"$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

write_preflight() {
    local profile="$1" signal="$2" value="$3" tracking="$4" digest="$5" tmp="${PREFLIGHT_FILE}.tmp.$$"
    install -d -m 0700 "$STATE_ROOT"
    {
        printf 'source_profile=%s\n' "$profile"
        printf 'source_signal=%s\n' "$signal"
        printf 'source_evidence=%s\n' "$value"
        printf 'target_tracking_ref=%s\n' "$tracking"
        printf 'target_resolved_digest=%s\n' "$digest"
        printf 'status=ready\n'
    } >"$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$PREFLIGHT_FILE"
}

state_value() {
    local key="$1" file="${2:-$STATE_FILE}"
    [[ -f "$file" ]] || return 0
    sed -n "s/^${key}=//p" "$file" | sed -n '1p'
}

home_directories() {
    local home_root
    home_root="$(root_path /var/home)"
    [[ -d "$home_root" ]] || return 0
    find "$home_root" -mindepth 1 -maxdepth 1 -type d \
        ! -name lost+found ! -name root ! -name nobody -printf '%f\n' | sort
}

capture_state() {
    local profile tracking digest transition_id transition_dir passwd_file group_file home_root user
    [[ -f "$PREFLIGHT_FILE" ]] || DIE 'refusing capture before preflight'
    require_source >/dev/null
    profile="$SOURCE_PROFILE"
    tracking="$(state_value target_tracking_ref "$PREFLIGHT_FILE")"
    digest="$(state_value target_resolved_digest "$PREFLIGHT_FILE")"
    [[ -n "$tracking" && -n "$digest" ]] || DIE 'preflight has no target tracking ref and resolved digest'
    transition_id="$(date +%Y%m%d-%H%M%S)-$$"
    transition_dir="${STATE_ROOT}/${transition_id}"
    mkdir -p "${transition_dir}/source" "${transition_dir}/homes"
    chmod 0700 "$transition_dir" "${transition_dir}/source" "${transition_dir}/homes"

    passwd_file="$(root_path /etc/passwd)"
    group_file="$(root_path /etc/group)"
    # Identity-only snapshots intentionally omit passwd/shadow fields and all
    # password hashes, keys, tokens, and user data.
    if [[ -f "$passwd_file" ]]; then
        awk -F: '{print $1 ":" $3 ":" $4 ":" $6 ":" $7}' "$passwd_file" >"${transition_dir}/source/users"
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
        stat -c '%n %u %g' "${home_root}/${user}" >>"${transition_dir}/source/homes"
    done < <(home_directories)

    printf '%s\n' "$SOURCE_VALUE" >"${transition_dir}/source/evidence"
    write_state captured "$profile" "$tracking" "$digest" "$transition_dir" ""
    printf 'source_profile=%s\nsource_signal=%s\nstatus=captured\ntarget_tracking_ref=%s\ntarget_resolved_digest=%s\ntransition_dir=%s\n' \
        "$profile" "$SOURCE_SIGNAL" "$tracking" "$digest" "$transition_dir"
}

backup_state() {
    local stage profile tracking digest transition_dir backup_dir home_root user relative source destination
    stage="$(state_value stage)"
    [[ "$stage" == captured ]] || DIE 'refusing backup before state capture'
    profile="$(state_value source_profile)"
    tracking="$(state_value target_tracking_ref)"
    digest="$(state_value target_resolved_digest)"
    transition_dir="$(state_value transition_dir)"
    backup_dir="${transition_dir}/backup"
    mkdir -p "$backup_dir"
    chmod 0700 "$backup_dir"
    home_root="$(root_path /var/home)"
    while IFS= read -r user; do
        [[ -n "$user" ]] || continue
        while IFS= read -r relative; do
            source="${home_root}/${user}/${relative}"
            [[ -e "$source" || -L "$source" ]] || continue
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
    write_state backed-up "$profile" "$tracking" "$digest" "$transition_dir" "$backup_dir"
    printf 'status=backed-up\nbackup_dir=%s\ntarget_tracking_ref=%s\ntarget_resolved_digest=%s\n' "$backup_dir" "$tracking" "$digest"
}

apply_switch() {
    local tracking="" confirm=0 stage profile transition_dir backup_dir expected actual
    while (($#)); do
        case "$1" in
            --confirm) confirm=1 ;;
            --) shift; break ;;
            -*) DIE "unknown apply option: $1" ;;
            *) [[ -z "$tracking" ]] || DIE 'apply accepts one target tracking ref'; tracking="$1" ;;
        esac
        shift
    done
    [[ -n "$tracking" ]] || DIE 'apply requires a target tracking ref'
    (( confirm == 1 )) || DIE 'refusing to switch without explicit --confirm'
    [[ "$ROOT" == "/" ]] || DIE 'apply must run on the live source system'
    stage="$(state_value stage)"
    [[ "$stage" == backed-up ]] || DIE 'refusing to switch before state capture and backup'
    profile="$(state_value source_profile)"
    transition_dir="$(state_value transition_dir)"
    backup_dir="$(state_value backup_dir)"
    [[ "$tracking" == "$(state_value target_tracking_ref)" ]] || DIE 'target tracking ref does not match preflight'
    expected="$(state_value target_resolved_digest)"
    actual="$(resolve_digest "$tracking")"
    [[ "$actual" == "$expected" ]] || DIE "target digest moved after preflight: expected ${expected}, found ${actual}"
    # The switch deliberately uses the mutable tracking ref, not the digest.
    "$BOOTC_BIN" switch "$tracking"
    write_state switched "$profile" "$tracking" "$expected" "$transition_dir" "$backup_dir"
    printf 'status=switched\nreboot_required=yes\ntarget_tracking_ref=%s\ntarget_resolved_digest=%s\n' "$tracking" "$expected"
}

verify_boot() {
    local expected actual status
    expected="$(state_value target_resolved_digest "$PREFLIGHT_FILE")"
    [[ "$expected" =~ ^sha256:[[:xdigit:]]{64}$ ]] || DIE 'preflight has no accepted resolved digest'
    status="$(status_json 2>/dev/null || true)"
    actual="$(printf '%s\n' "$status" | grep -Eio 'sha256:[[:xdigit:]]{64}' | head -n 1 || true)"
    [[ "$actual" == "$expected" ]] || DIE "booted deployment digest is not the accepted digest (expected ${expected}, found ${actual:-none})"
    printf 'status=verified\nbooted_digest=%s\n' "$actual"
}

recover_transition() {
    local confirm=0 stage
    while (($#)); do
        case "$1" in
            --confirm) confirm=1 ;;
            *) DIE "unknown recover option: $1" ;;
        esac
        shift
    done
    (( confirm == 1 )) || DIE 'refusing recovery without explicit --confirm'
    stage="$(state_value stage)"
    [[ "$stage" == switched || "$stage" == adopted ]] || DIE 'no switched transition is ready for recovery'
    if [[ "$ROOT" == "/" && -x /usr/bin/omarchy-adoption-rollback ]]; then
        /usr/bin/omarchy-adoption-rollback
    else
        DIE 'target-side omarchy-adoption-rollback is unavailable; recover from the target system'
    fi
    write_state recovered "$(state_value source_profile)" "$(state_value target_tracking_ref)" \
        "$(state_value target_resolved_digest)" "$(state_value transition_dir)" "$(state_value backup_dir)"
    printf 'status=recovered\nbootc_rollback_is_separate=yes\n'
}

preflight() {
    local tracking="$1" digest
    require_tracking_ref "$tracking"
    require_source >/dev/null
    [[ -d "$(root_path /var/home)" ]] || DIE '/var/home is not available for state-aware transition'
    digest="$(resolve_digest "$tracking")"
    write_preflight "$SOURCE_PROFILE" "$SOURCE_SIGNAL" "$SOURCE_VALUE" "$tracking" "$digest"
    printf 'source_profile=%s\nsource_signal=%s\nsource_evidence=%s\ntarget_tracking_ref=%s\ntarget_resolved_digest=%s\nstatus=ready\n' \
        "$SOURCE_PROFILE" "$SOURCE_SIGNAL" "$SOURCE_VALUE" "$tracking" "$digest"
}

usage() {
    cat <<'EOF'
Usage:
  omarchy-transition inspect-source
  omarchy-transition preflight <registry/image:tracking-ref>
  omarchy-transition capture-state
  omarchy-transition backup
  omarchy-transition apply --confirm <registry/image:tracking-ref>
  omarchy-transition verify-boot
  omarchy-transition recover --confirm

Supported source profiles are current Project Bluefin Dakota, Dudley Dakota,
Bluefin, and existing Omarchy bootc. Unknown systems are refused rather than
inferred from a familiar NAME. Recovery of mutable adoption state is separate
from bootc deployment rollback.
EOF
}

command_name="${1:-}"
shift || true
case "$command_name" in
    inspect-source) (($# == 0)) || DIE 'inspect-source accepts no arguments'; inspect_source ;;
    preflight) (($# == 1)) || DIE 'preflight accepts exactly one tracking ref'; preflight "$1" ;;
    capture-state) (($# == 0)) || DIE 'capture-state accepts no arguments'; capture_state ;;
    backup) (($# == 0)) || DIE 'backup accepts no arguments'; backup_state ;;
    apply) apply_switch "$@" ;;
    verify-boot) (($# == 0)) || DIE 'verify-boot accepts no arguments'; verify_boot ;;
    recover|adoption-rollback) recover_transition "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
