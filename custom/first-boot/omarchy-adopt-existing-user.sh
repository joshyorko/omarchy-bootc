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
STATE_FILE="${STATE_ROOT}/state.env"

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

state_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$STATE_FILE" | head -n 1
}

write_state() {
    local status="$1" user="$2" home="$3" uid="$4" gid="$5"
    local backup_root="$6" rollback_root="$7" manifest="$8"
    local created_user="$9" created_group="${10}" group_name="${11}"
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

backup_path() {
    local relative="$1"
    local source="${HOME}/${relative}"
    local destination="${BACKUP_ROOT}/${relative}"

    record_managed_path "$relative"
    if path_exists "$source"; then
        install -d -m 0700 "$(dirname "$destination")"
        cp -a -- "$source" "$destination"
    fi
}

backup_application_conflicts() {
    local source relative
    [[ -d /usr/share/omarchy/applications ]] || return 0
    for source in /usr/share/omarchy/applications/*.desktop; do
        [[ -f "$source" ]] || continue
        relative=".local/share/applications/$(basename "$source")"
        if path_exists "${HOME}/${relative}"; then
            managed_paths+=("$relative")
            protected_paths+=("$relative")
        fi
    done
}

restore_protected_paths() {
    local relative source destination generated
    for relative in "${protected_paths[@]}"; do
        source="${BACKUP_ROOT}/${relative}"
        destination="${HOME}/${relative}"
        path_exists "$source" || continue

        if path_exists "$destination"; then
            generated="${ROLLBACK_ROOT}/after/${relative}"
            install -d -m 0700 "$(dirname "$generated")"
            mv -- "$destination" "$generated"
        fi
        install -d -m 0700 "$(dirname "$destination")"
        cp -a -- "$source" "$destination"
    done
}

run_rollback() {
    [[ -f "$STATE_FILE" ]] || {
        echo "No Omarchy adoption state exists at ${STATE_FILE}." >&2
        exit 1
    }

    local user home backup_root rollback_root manifest created_user created_group group_name
    user="$(state_value user)"
    home="$(state_value home)"
    backup_root="$(state_value backup_root)"
    rollback_root="$(state_value rollback_root)"
    manifest="$(state_value manifest)"
    created_user="$(state_value created_user)"
    created_group="$(state_value created_group)"
    group_name="$(state_value group_name)"

    [[ -n "$user" && -d "$home" && -f "$manifest" ]] || {
        echo "Adoption state is incomplete; refusing an unscoped rollback." >&2
        exit 1
    }

    local relative source destination preserved
    while IFS= read -r relative; do
        [[ -n "$relative" ]] || continue
        source="${backup_root}/${relative}"
        destination="${home}/${relative}"
        if path_exists "$destination"; then
            preserved="${rollback_root}/rollback-current/${relative}"
            install -d -m 0700 "$(dirname "$preserved")"
            mv -- "$destination" "$preserved"
        fi
        if path_exists "$source"; then
            install -d -m 0700 "$(dirname "$destination")"
            cp -a -- "$source" "$destination"
        fi
    done <"$manifest"

    if [[ "$created_user" == 1 ]] && getent passwd "$user" >/dev/null; then
        userdel "$user"
    fi
    if [[ "$created_group" == 1 && -n "$group_name" ]] && getent group "$group_name" >/dev/null; then
        groupdel "$group_name" || true
    fi

    write_state \
        "rolled-back" "$user" "$home" "$(state_value uid)" "$(state_value gid)" \
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
uid="$(stat -c '%u' "$HOME")"
gid="$(stat -c '%g' "$HOME")"
run_id="$(date +%Y%m%d-%H%M%S)-$$"
RUN_ROOT="${STATE_ROOT}/runs/${run_id}"
BACKUP_ROOT="${RUN_ROOT}/backup"
ROLLBACK_ROOT="${RUN_ROOT}/rollback"
MANIFEST="${RUN_ROOT}/managed-paths"
install -d -m 0700 "$RUN_ROOT" "$BACKUP_ROOT" "$ROLLBACK_ROOT"
: >"$MANIFEST"
backup_application_conflicts
for relative in "${managed_paths[@]}"; do
    backup_path "$relative"
done

created_user=0
created_group=0
group_name=""
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
        groupadd --gid "$gid" "$group_name"
        created_group=1
    fi
    useradd --uid "$uid" --gid "$gid" --home-dir "$HOME" --no-create-home --shell /bin/bash "$selected_user"
    created_user=1
    for group in wheel video audio input network; do
        getent group "$group" >/dev/null && usermod --append --groups "$group" "$selected_user"
    done

    password="$(systemd-ask-password --timeout=300 "Create a password for ${selected_user}")" || {
        write_state "needs-password" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name"
        exit 1
    }
    [[ -n "$password" ]] || {
        write_state "needs-password" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name"
        exit 1
    }
    printf '%s:%s\n' "$selected_user" "$password" | chpasswd
fi

write_state "running" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name"

if ! runuser --user "$selected_user" -- env \
    HOME="$HOME" USER="$selected_user" LOGNAME="$selected_user" \
    OMARCHY_SETUP_CONTEXT=bootc-adoption \
    OMARCHY_PATH=/usr/share/omarchy \
    OMARCHY_INSTALL=/usr/share/omarchy/install \
    PATH=/usr/share/omarchy/bin:/usr/local/bin:/usr/bin \
    /usr/bin/omarchy-provision-user --first-install; then
    write_state "failed" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name"
    exit 1
fi

restore_protected_paths
write_state "complete" "$selected_user" "$HOME" "$uid" "$gid" "$BACKUP_ROOT" "$ROLLBACK_ROOT" "$MANIFEST" "$created_user" "$created_group" "$group_name"
echo "Omarchy adoption complete for ${selected_user}; existing user data was preserved."
