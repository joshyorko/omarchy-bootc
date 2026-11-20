#!/usr/bin/env bash
set -euo pipefail

# Cross-distro bootc switch adoption.  Fresh ISO installs write
# /var/lib/omarchy-bootc/installer-origin and are handled by the upstream ISO
# provisioning path instead.  This script never copies a whole skeleton over
# an existing home and never deletes user data.

HOME_ROOT="${OMARCHY_ADOPTION_HOME_ROOT:-/var/home}"
STATE_ROOT="${OMARCHY_ADOPTION_STATE_ROOT:-/var/lib/omarchy-bootc/adoption}"
INSTALLER_ORIGIN="${OMARCHY_INSTALLER_ORIGIN_FILE:-/var/lib/omarchy-bootc/installer-origin}"
USER_SELECTION="${OMARCHY_ADOPTION_USER_FILE:-/etc/omarchy/adoption-user}"
PROVISION_BIN="${OMARCHY_ADOPTION_PROVISION_BIN:-/usr/bin/omarchy-provision-user}"
STATE_FILE="${STATE_ROOT}/state.env"
FS_HELPER="$(dirname -- "${BASH_SOURCE[0]}")/omarchy-adoption-filesystem.py"

adoption_fs() {
    python3 "$FS_HELPER" "$@"
}

managed_paths=(
    ".config/hypr"
    ".config/omarchy"
    ".config/gtk-3.0/bookmarks"
    ".config/user-dirs.dirs"
    ".config/user-dirs.locale"
    ".config/mimeapps.list"
    ".local/state/omarchy"
    ".local/share/keyrings"
    ".local/share/mise/config.toml"
    ".local/share/mise/settings.toml"
    ".agents/skills"
    ".claude/skills"
    ".codex/skills"
    ".gemini/skills"
    ".hermes/skills"
    ".pi/agent/skills"
    ".XCompose"
    ".gitconfig"
    "Work/.mise.toml"
)

# Existing user-owned settings are restored immediately after the upstream
# finalizer.  Newly generated replacements are moved to rollback-current so
# an explicit rollback never destroys the work the adoption just produced.
protected_paths=(
    ".config/hypr"
    ".config/user-dirs.dirs"
    ".config/user-dirs.locale"
    ".config/mimeapps.list"
    ".agents/skills"
    ".claude/skills"
    ".codex/skills"
    ".gemini/skills"
    ".hermes/skills"
    ".pi/agent/skills"
    ".XCompose"
    ".gitconfig"
    "Work/.mise.toml"
)

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

# Confine all home reads/mutations strictly inside the intended user's real
# home directory; refuse traversal components or symlinked ancestor directories.
ensure_safe_home_path() {
    local home="$1" relative="$2"
    local parent="" segment="" cursor=""
    local -a segments=()

    [[ -n "$home" && ! -L "$home" && -d "$home" ]] || {
        echo "Refusing unsafe adoption home directory: ${home}" >&2
        return 1
    }
    [[ -n "$relative" && "$relative" != /* && "$relative" != *$'\n'* && "$relative" != *$'\t'* && "$relative" != *$'\r'* ]] || {
        echo "Refusing absolute or empty relative adoption path: ${relative}" >&2
        return 1
    }
    IFS='/' read -r -a segments <<<"$relative"
    for segment in "${segments[@]}"; do
        [[ -n "$segment" && "$segment" != "." && "$segment" != ".." ]] || {
            echo "Refusing traversal segment in adoption path: ${relative}" >&2
            return 1
        }
    done
    parent="$(dirname "$relative")"
    if [[ "$parent" != "." ]]; then
        cursor="$home"
        IFS='/' read -r -a segments <<<"$parent"
        for segment in "${segments[@]}"; do
            cursor="${cursor}/${segment}"
            if [[ -L "$cursor" ]]; then
                echo "Refusing symlinked parent directory inside home: ${cursor}" >&2
                return 1
            fi
            if [[ -e "$cursor" && ! -d "$cursor" ]]; then
                echo "Refusing non-directory parent inside home: ${cursor}" >&2
                return 1
            fi
        done
    fi
}

ensure_user_parent_dir() {
    local home="$1" relative="$2" owner_uid="$3" owner_gid="$4" parent
    ensure_safe_home_path "$home" "$relative"
    parent="$(dirname "$relative")"
    [[ $parent != . ]] || return 0
    adoption_fs mkdir "$home" "$parent" "$owner_uid" "$owner_gid"
}

is_protected_path() {
    local target="$1" candidate=""
    for candidate in "${protected_paths[@]}"; do
        [[ "$candidate" == "$target" ]] && return 0
    done
    return 1
}

state_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$STATE_FILE" | head -n 1
}

write_state() {
    local status="$1" user="$2" home="$3" uid="$4" gid="$5"
    local backup_root="$6" rollback_root="$7" manifest="$8"
    local created_user="$9" created_group="${10}" group_name="${11}"
    local auth_ready="${12:-unknown}"
    local tmp="${STATE_FILE}.tmp.$$"

    install -d -m 0700 "$STATE_ROOT"
    {
        printf 'status=%s\n' "$status"
        printf 'user=%s\n' "$user"
        printf 'home=%s\n' "$home"
        printf 'uid=%s\n' "$uid"
        printf 'gid=%s\n' "$gid"
        printf 'backup_root=%s\n' "$backup_root"
        printf 'rollback_root=%s\n' "$rollback_root"
        printf 'manifest=%s\n' "$manifest"
        printf 'created_user=%s\n' "$created_user"
        printf 'created_group=%s\n' "$created_group"
        printf 'group_name=%s\n' "$group_name"
        printf 'auth_ready=%s\n' "$auth_ready"
    } >"$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

record_managed_path() {
    local relative="$1"
    if ! grep -Fxq "$relative" "$MANIFEST" 2>/dev/null; then
        printf '%s\n' "$relative" >>"$MANIFEST"
    fi
}

backup_application_conflicts() {
    local source relative
    [[ -d /usr/share/omarchy/applications ]] || return 0
    for source in /usr/share/omarchy/applications/*.desktop; do
        [[ -f "$source" ]] || continue
        relative=".local/share/applications/$(basename "$source")"
        ensure_safe_home_path "$HOME" "$relative"
        if path_exists "${HOME}/${relative}"; then
            managed_paths+=("$relative")
            protected_paths+=("$relative")
        fi
    done
}

discover_hermes_profile_skills() {
    local profiles_root="${HOME}/.hermes/profiles"
    local profile="" name="" relative=""
    [[ ! -L "${HOME}/.hermes" && ! -L "$profiles_root" && -d "$profiles_root" ]] || return 0
    for profile in "$profiles_root"/*; do
        [[ ! -L "$profile" && -d "$profile" ]] || continue
        name="$(basename "$profile")"
        relative=".hermes/profiles/${name}/skills"
        ensure_safe_home_path "$HOME" "$relative"
        if path_exists "${HOME}/${relative}"; then
            managed_paths+=("$relative")
            protected_paths+=("$relative")
        fi
    done
}

# Freeze the pre-adoption present/absent baseline exactly once per run so that a
# crash/retry after partial provisioning never promotes newly created files into
# the pre-adoption backup.
freeze_baseline() {
    local relative="" source="" destination="" protected_flag=""
    local tmp="${BASELINE_FILE}.tmp.$$"

    if [[ -f "$BASELINE_DONE" && -f "$BASELINE_FILE" ]]; then
        return 0
    fi

    backup_application_conflicts
    discover_hermes_profile_skills
    : >"$tmp"
    for relative in "${managed_paths[@]}"; do
        ensure_safe_home_path "$HOME" "$relative"
        record_managed_path "$relative"
        protected_flag=0
        if is_protected_path "$relative"; then
            protected_flag=1
        fi
        source="${HOME}/${relative}"
        destination="${BACKUP_ROOT}/${relative}"
        if path_exists "$source"; then
            if ! path_exists "$destination"; then
                adoption_fs copy "$HOME" "$relative" "$BACKUP_ROOT" "$relative"
            fi
            printf 'present\t%s\t%s\n' "$protected_flag" "$relative" >>"$tmp"
        else
            printf 'absent\t%s\t%s\n' "$protected_flag" "$relative" >>"$tmp"
        fi
    done
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$BASELINE_FILE"
    : >"$BASELINE_DONE"
}

# Preserve every existing user file in a restored directory while seeding any
# required missing files (e.g. hyprland.lua or official skill links) generated
# by upstream provisioning.
seed_missing_from_generated() {
    local relative="$1" owner_uid="$2" owner_gid="$3"
    adoption_fs seed "$ROLLBACK_ROOT" "after/$relative" "$HOME" "$relative" "$owner_uid" "$owner_gid"
}

restore_protected_paths() {
    local presence="" protected_flag="" relative="" source="" destination="" generated=""

    [[ -f "$BASELINE_FILE" ]] || {
        echo "Frozen adoption baseline is missing: ${BASELINE_FILE}" >&2
        return 1
    }
    while IFS=$'\t' read -r presence protected_flag relative; do
        [[ "$presence" == present && "$protected_flag" == 1 && -n "$relative" ]] || continue
        ensure_safe_home_path "$HOME" "$relative"
        source="${BACKUP_ROOT}/${relative}"
        destination="${HOME}/${relative}"
        path_exists "$source" || continue

        generated="${ROLLBACK_ROOT}/after/${relative}"
        if path_exists "$destination"; then
            if path_exists "$generated"; then
                adoption_fs remove "$ROLLBACK_ROOT" "after/$relative"
            fi
            adoption_fs move "$HOME" "$relative" "$ROLLBACK_ROOT" "after/$relative"
        fi
        ensure_user_parent_dir "$HOME" "$relative" "$uid" "$gid"
        adoption_fs copy "$BACKUP_ROOT" "$relative" "$HOME" "$relative"
        if [[ ! -L "$source" && -d "$source" && ! -L "$generated" && -d "$generated" ]]; then
            seed_missing_from_generated "$relative" "$uid" "$gid"
        fi
    done <"$BASELINE_FILE"
}

run_rollback() {
    [[ -f "$STATE_FILE" ]] || {
        echo "No Omarchy adoption state exists at ${STATE_FILE}." >&2
        exit 1
    }

    local user home uid gid backup_root rollback_root manifest created_user created_group group_name
    user="$(state_value user)"
    home="$(state_value home)"
    uid="$(state_value uid)"
    gid="$(state_value gid)"
    backup_root="$(state_value backup_root)"
    rollback_root="$(state_value rollback_root)"
    manifest="$(state_value manifest)"
    created_user="$(state_value created_user)"
    created_group="$(state_value created_group)"
    group_name="$(state_value group_name)"

    [[ -n "$user" && -d "$home" && ! -L "$home" && -f "$manifest" ]] || {
        echo "Adoption state is incomplete; refusing an unscoped rollback." >&2
        exit 1
    }

    local relative source destination
    while IFS= read -r relative; do
        [[ -n "$relative" ]] || continue
        ensure_safe_home_path "$home" "$relative"
        source="${backup_root}/${relative}"
        destination="${home}/${relative}"
        if path_exists "$destination"; then
            adoption_fs move "$home" "$relative" "$rollback_root" "rollback-current/$relative"
        fi
        if path_exists "$source"; then
            ensure_user_parent_dir "$home" "$relative" "$uid" "$gid"
            adoption_fs copy "$backup_root" "$relative" "$home" "$relative"
        fi
    done <"$manifest"

    if [[ "$created_user" == 1 ]] && getent passwd "$user" >/dev/null; then
        userdel "$user"
    fi
    if [[ "$created_group" == 1 && -n "$group_name" ]] && getent group "$group_name" >/dev/null; then
        groupdel "$group_name" || true
    fi

    write_state \
        "rolled-back" "$user" "$home" "$uid" "$gid" \
        "$backup_root" "$rollback_root" "$manifest" 0 0 "$group_name"
    echo "Omarchy adoption rolled back for ${user}; post-adoption files are retained under ${rollback_root}."
}

if [[ "${1:-}" == "--rollback" || "$(basename "$0")" == "omarchy-adoption-rollback" ]]; then
    run_rollback
    exit 0
fi

if [[ -f "$INSTALLER_ORIGIN" ]]; then
    write_state "fresh-iso" "" "" "" "" "" "" "" 0 0 ""
    exit 0
fi

if [[ -f "$STATE_FILE" ]]; then
    case "$(state_value status)" in
        complete|fresh-iso|no-existing-user|rolled-back)
            exit 0
            ;;
    esac
fi

resume=0
if [[ -f "$STATE_FILE" ]]; then
    case "$(state_value status)" in
        preparing|backed-up|needs-password|creating-group|creating-user|account-created|running|failed)
            resume=1
            selected_user="$(state_value user)"
            HOME="$(state_value home)"
            uid="$(state_value uid)"
            gid="$(state_value gid)"
            BACKUP_ROOT="$(state_value backup_root)"
            ROLLBACK_ROOT="$(state_value rollback_root)"
            MANIFEST="$(state_value manifest)"
            created_user="$(state_value created_user)"
            created_group="$(state_value created_group)"
            group_name="$(state_value group_name)"
            RUN_ROOT="$(dirname "$BACKUP_ROOT")"
            BASELINE_FILE="${RUN_ROOT}/baseline.tsv"
            BASELINE_DONE="${RUN_ROOT}/baseline.done"
            [[ -n "$selected_user" && -d "$HOME" && ! -L "$HOME" && -n "$MANIFEST" ]] || {
                echo 'Adoption recovery state is incomplete; refusing to restart from a fresh baseline.' >&2
                exit 1
            }
            ;;
    esac
fi

if (( resume == 0 )); then
    mapfile -t candidates < <(
        if [[ -d "$HOME_ROOT" ]]; then
            find "$HOME_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
        fi | while IFS= read -r candidate; do
            case "$candidate" in
                lost+found|root|nobody) continue ;;
            esac
            valid_username "$candidate" || continue
            candidate_uid="$(stat -c '%u' "${HOME_ROOT}/${candidate}" 2>/dev/null || true)"
            [[ "$candidate_uid" =~ ^[0-9]+$ ]] || continue
            (( candidate_uid >= 1000 && candidate_uid < 60000 )) || continue
            printf '%s\n' "$candidate"
        done
    )

    if (( ${#candidates[@]} == 0 )); then
        write_state "no-existing-user" "" "" "" "" "" "" "" 0 0 ""
        exit 0
    fi

    selected_user=""
    if [[ -f "$USER_SELECTION" ]]; then
        IFS= read -r selected_user <"$USER_SELECTION" || true
        valid_username "$selected_user" || {
            write_state "needs-selection" "" "" "" "" "" "" "" 0 0 ""
            echo "Invalid adoption user selection: ${USER_SELECTION}" >&2
            exit 1
        }
        if ! printf '%s\n' "${candidates[@]}" | grep -Fxq "$selected_user"; then
            write_state "needs-selection" "" "" "" "" "" "" "" 0 0 ""
            echo "Selected adoption user is not an existing home: ${selected_user}" >&2
            exit 1
        fi
    elif (( ${#candidates[@]} == 1 )); then
        selected_user="${candidates[0]}"
    else
        candidate_list="$(IFS=,; printf '%s' "${candidates[*]}")"
        write_state "needs-selection" "$candidate_list" "" "" "" "" "" "" 0 0 ""
        echo "Multiple existing homes found; set ${USER_SELECTION} and rerun ${0}." >&2
        exit 1
    fi

    HOME="${HOME_ROOT}/${selected_user}"
    [[ ! -L "$HOME" && -d "$HOME" ]] || {
        echo "Refusing symlinked or missing adoption home: ${HOME}" >&2
        exit 1
    }
    uid="$(stat -c '%u' "$HOME")"
    gid="$(stat -c '%g' "$HOME")"
    run_id="$(date +%Y%m%d-%H%M%S)-$$"
    RUN_ROOT="${STATE_ROOT}/runs/${run_id}"
    BACKUP_ROOT="${RUN_ROOT}/backup"
    ROLLBACK_ROOT="${RUN_ROOT}/rollback"
    MANIFEST="${RUN_ROOT}/managed-paths"
    BASELINE_FILE="${RUN_ROOT}/baseline.tsv"
    BASELINE_DONE="${RUN_ROOT}/baseline.done"
    install -d -m 0700 "$RUN_ROOT" "$BACKUP_ROOT" "$ROLLBACK_ROOT"
    : >"$MANIFEST"
    created_user=0
    created_group=0
    group_name=""
    write_state "preparing" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" 0 0 "" no
fi

install -d -m 0700 "$RUN_ROOT" "$BACKUP_ROOT" "$ROLLBACK_ROOT"
[[ -f "$MANIFEST" ]] || : >"$MANIFEST"
freeze_baseline
write_state "backed-up" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name" no

existing_passwd="$(getent passwd "$selected_user" || true)"
if [[ -n "$existing_passwd" ]]; then
    existing_uid="$(cut -d: -f3 <<<"$existing_passwd")"
    [[ "$existing_uid" == "$uid" ]] || {
        write_state "account-conflict" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" 0 0 ""
        echo "Existing account ${selected_user} has UID ${existing_uid}, home owner is ${uid}; refusing adoption." >&2
        exit 1
    }
else
    if getent passwd "$uid" >/dev/null; then
        write_state "uid-conflict" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" 0 0 ""
        echo "UID ${uid} is already assigned to another account; refusing adoption." >&2
        exit 1
    fi
    if getent group "$gid" >/dev/null; then
        group_name="$(getent group "$gid" | cut -d: -f1)"
    else
        group_name="$selected_user"
        write_state "creating-group" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" 0 1 "$group_name" no
        groupadd --gid "$gid" "$group_name"
        created_group=1
    fi
    write_state "creating-user" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" 1 "$created_group" "$group_name" no
    useradd --uid "$uid" --gid "$gid" --home-dir "$HOME" --no-create-home --shell /bin/bash "$selected_user"
    created_user=1
    write_state "account-created" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name" no
    for group in wheel video audio input network; do
        getent group "$group" >/dev/null && usermod --append --groups "$group" "$selected_user"
    done
fi

password_status="$(passwd -S "$selected_user" 2>/dev/null | awk '{print $2}' || true)"
if [[ "$password_status" != P ]]; then
    write_state "needs-password" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name" no
    password="$(systemd-ask-password --timeout=300 "Create a password for ${selected_user}")" || exit 1
    [[ -n "$password" ]] || exit 1
    printf '%s:%s\n' "$selected_user" "$password" | chpasswd
    password_status="$(passwd -S "$selected_user" 2>/dev/null | awk '{print $2}' || true)"
fi
[[ "$password_status" == P ]] || {
    write_state "needs-password" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name" no
    echo "Account ${selected_user} still has no usable password; adoption remains pending." >&2
    exit 1
}

write_state "running" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name" yes

if ! runuser --user "$selected_user" -- env \
    HOME="$HOME" USER="$selected_user" LOGNAME="$selected_user" \
    OMARCHY_SETUP_CONTEXT=bootc-adoption \
    OMARCHY_PATH=/usr/share/omarchy \
    OMARCHY_INSTALL=/usr/share/omarchy/install \
    PATH=/usr/share/omarchy/bin:/usr/local/bin:/usr/bin \
    "$PROVISION_BIN" --first-install; then
    write_state "failed" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name" yes
    exit 1
fi

restore_protected_paths
write_state "complete" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name" yes
echo "Omarchy adoption complete for ${selected_user}; existing user data was preserved."
