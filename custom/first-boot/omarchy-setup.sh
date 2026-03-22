#!/usr/bin/bash
# shellcheck shell=bash
#
# omarchy-setup.sh — First-boot root-level setup
#
# Executed once by omarchy-firstboot.service (runs as root) on first successful
# multi-user boot after image deployment. Steps should remain idempotent.
#
# Responsibility boundary
#   Image build (Containerfile + build/*.sh):
#     - install OS packages and systemd units
#     - stage default config assets under /usr/share/omarchy
#   Root first-boot (this script):
#     - one-time machine setup requiring root
#     - seed user-facing starter files when a primary user exists
#   User session setup (deferred):
#     - dotfiles, shell/editor customization, theme preference, app login
#     - should be implemented later as a user systemd unit or login hook

set -eoux pipefail

FIRSTBOOT_STAMP="/var/lib/omarchy/.firstboot-done"

if [[ -f "${FIRSTBOOT_STAMP}" ]]; then
    echo "omarchy-firstboot: already completed — exiting."
    exit 0
fi

echo ":: omarchy-bootc first-boot setup starting (running as root)..."

# ── System-level state location ───────────────────────────────────────────────
mkdir -p /var/lib/omarchy

# ── Install per-user starter assets for the primary user (if present) ────────
PRIMARY_USER=""
while IFS=: read -r uname _ uid _; do
    if [[ "${uid}" -ge 1000 ]]; then
        PRIMARY_USER="${uname}"
        break
    fi
done < /etc/passwd

if [[ -n "${PRIMARY_USER}" ]]; then
    USER_HOME=$(getent passwd "${PRIMARY_USER}" | cut -d: -f6)
    echo "  Primary user: ${PRIMARY_USER} (home: ${USER_HOME})"

    # Seed starter Hyprland config from image-staged skeleton.
    HYPR_CONF_DIR="${USER_HOME}/.config/hypr"
    HYPR_CONF="${HYPR_CONF_DIR}/hyprland.conf"
    SKELETON="/usr/share/omarchy/hypr/hyprland.conf.example"

    if [[ ! -f "${HYPR_CONF}" && -f "${SKELETON}" ]]; then
        mkdir -p "${HYPR_CONF_DIR}"
        cp "${SKELETON}" "${HYPR_CONF}"
        chown -R "${PRIMARY_USER}:${PRIMARY_USER}" "${HYPR_CONF_DIR}"
        echo "  Hyprland config deployed to ${HYPR_CONF}"
    fi

    # Leave an explicit marker describing deferred user-session setup work.
    TODO_DIR="${USER_HOME}/.config/omarchy"
    TODO_FILE="${TODO_DIR}/NEXT_STEPS.txt"
    if [[ ! -f "${TODO_FILE}" ]]; then
        mkdir -p "${TODO_DIR}"
        cat > "${TODO_FILE}" <<'EOT'
omarchy-bootc user-session setup is intentionally minimal in this POC.

Deferred work:
- user systemd unit or login hook for Omarchy-specific configuration
- dotfiles/bootstrap tooling integration
- theming polish (GTK/icons/cursors)
- application-level defaults
EOT
        chown -R "${PRIMARY_USER}:${PRIMARY_USER}" "${TODO_DIR}"
    fi
else
    echo "  No primary user found (UID >= 1000) — skipping user-level starter setup."
    echo "  Re-enable omarchy-firstboot.service after creating a user if needed."
fi

touch "${FIRSTBOOT_STAMP}"

echo ":: omarchy-bootc first-boot setup complete."
