#!/usr/bin/bash
# shellcheck shell=bash
#
# omarchy-setup.sh — First-boot root-level setup
#
# Responsibilities:
#   - image build creates baseline packages, default login user, and system units
#   - this first-boot script performs one-time root tasks and user-home seeding
#   - per-user session customization remains deferred

set -eoux pipefail

FIRSTBOOT_STAMP="/var/lib/omarchy/.firstboot-done"
DEFAULT_USER="omarchy"

if [[ -f "${FIRSTBOOT_STAMP}" ]]; then
    echo "omarchy-firstboot: already completed — exiting."
    exit 0
fi

echo ":: omarchy-bootc first-boot setup starting (running as root)..."
mkdir -p /var/lib/omarchy

# Fallback: ensure the documented default user exists, even if image creation
# changed in the future.
if ! id -u "${DEFAULT_USER}" >/dev/null 2>&1; then
    useradd -m -G wheel,video,audio,input,network -s /bin/bash "${DEFAULT_USER}"
    echo "${DEFAULT_USER}:${DEFAULT_USER}" | chpasswd
fi

USER_HOME=$(getent passwd "${DEFAULT_USER}" | cut -d: -f6)
echo "  Session user: ${DEFAULT_USER} (home: ${USER_HOME})"

# Seed starter desktop config from image-staged skeleton.
if [[ -d /usr/share/omarchy/skel ]]; then
    cp -a -n /usr/share/omarchy/skel/. "${USER_HOME}/"
fi

# Seed starter Hyprland config from image-staged defaults.
HYPR_CONF_DIR="${USER_HOME}/.config/hypr"
SKELETON_DIR="/usr/share/omarchy/hypr"

if [[ -d "${SKELETON_DIR}" ]]; then
    rm -rf "${HYPR_CONF_DIR}"
    mkdir -p "${HYPR_CONF_DIR}"
    cp -a "${SKELETON_DIR}/". "${HYPR_CONF_DIR}/"
fi

# Record deferred user-session tasks in the user's home.
TODO_DIR="${USER_HOME}/.config/omarchy"
TODO_FILE="${TODO_DIR}/NEXT_STEPS.txt"
if [[ ! -f "${TODO_FILE}" ]]; then
    mkdir -p "${TODO_DIR}"
    cat > "${TODO_FILE}" <<'EOT'
omarchy-bootc session customization is intentionally minimal in this POC.

Deferred work:
- user systemd unit/login hook for Omarchy-specific setup
- dotfiles/bootstrap tooling integration
- theming polish (GTK/icons/cursors)
- application-level defaults
EOT
fi

mkdir -p "${USER_HOME}/Pictures/Screenshots"

chown -R "${DEFAULT_USER}:${DEFAULT_USER}" "${USER_HOME}/.config"
chown -R "${DEFAULT_USER}:${DEFAULT_USER}" "${USER_HOME}/Pictures"
touch "${FIRSTBOOT_STAMP}"

echo ":: omarchy-bootc first-boot setup complete."
