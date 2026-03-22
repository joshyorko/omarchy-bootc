#!/usr/bin/bash
# shellcheck shell=bash
#
# omarchy-setup.sh — First-boot system-level setup
#
# Executed once by omarchy-firstboot.service (runs as root) on the first boot
# after the image is deployed.  All steps are idempotent; re-running is safe.
#
# Separation of concerns
#   Build time  → build/10-base.sh, build/20-omarchy.sh  (OS packages)
#   First boot  → THIS FILE                               (system-level setup)
#   User login  → ~/.config/autostart or a user systemd unit (user-layer setup)
#
# NOTE: This service runs as root (no User= in the unit file).  Do NOT use
# $HOME or assume a specific user's home directory here.  User-specific
# configuration (dotfiles, Hyprland config, theming) should be performed by a
# separate user-session service or login hook, which can be installed here.

set -eoux pipefail

FIRSTBOOT_STAMP="/var/lib/omarchy/.firstboot-done"

if [[ -f "${FIRSTBOOT_STAMP}" ]]; then
    echo "omarchy-firstboot: already completed — exiting."
    exit 0
fi

echo ":: omarchy-bootc first-boot setup starting (running as root)..."

# ── System-level configuration ────────────────────────────────────────────────

# Ensure /var/lib/omarchy exists for future stamp files and state
mkdir -p /var/lib/omarchy

# ── Install per-user first-boot hook for the primary user ─────────────────────
# Determine the first non-root, non-system user (UID >= 1000) if one exists.
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

    # Deploy skeleton Hyprland config if the user doesn't have one yet
    HYPR_CONF_DIR="${USER_HOME}/.config/hypr"
    HYPR_CONF="${HYPR_CONF_DIR}/hyprland.conf"
    SKELETON="/usr/share/omarchy/hypr/hyprland.conf.example"

    if [[ ! -f "${HYPR_CONF}" && -f "${SKELETON}" ]]; then
        mkdir -p "${HYPR_CONF_DIR}"
        cp "${SKELETON}" "${HYPR_CONF}"
        chown -R "${PRIMARY_USER}:${PRIMARY_USER}" "${HYPR_CONF_DIR}"
        echo "  Hyprland config deployed to ${HYPR_CONF}"
    fi

    # ── Theming ──────────────────────────────────────────────────────────────
    # Placeholder: apply GTK theme, icon theme, cursor theme as the primary user
    # Example (run as user to reach the D-Bus session bus):
    #   runuser -l "${PRIMARY_USER}" -c \
    #     'gsettings set org.gnome.desktop.interface gtk-theme Catppuccin-Mocha-Standard-Mauve-Dark'

    # ── Dotfiles ──────────────────────────────────────────────────────────────
    # Placeholder: deploy dotfiles via chezmoi, stow, or a bare git repo.
    # Example:
    #   runuser -l "${PRIMARY_USER}" -c \
    #     'chezmoi init --apply https://github.com/YOURUSER/dotfiles.git'
else
    echo "  No primary user found (UID >= 1000) — skipping user-level setup."
    echo "  Re-enable the service after creating a user to run user setup."
fi

# ── Mark complete ─────────────────────────────────────────────────────────────
touch "${FIRSTBOOT_STAMP}"

echo ":: omarchy-bootc first-boot setup complete."
