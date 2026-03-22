#!/usr/bin/bash
# shellcheck shell=bash
#
# 30-services.sh — Enable / disable systemd services
#
# Runs after all packages are installed.  Adjust the lists below to match
# the packages installed in 10-base.sh and 20-omarchy.sh.

set -eoux pipefail

echo "::group:: Enable systemd services"

# Core networking
systemctl enable NetworkManager.service   || true
systemctl enable systemd-resolved.service || true

# Remote access (disable if not needed)
systemctl enable sshd.service || true

# Container socket (useful for local podman management)
systemctl enable podman.socket || true

echo "::endgroup::"

echo "::group:: Enable first-boot service"

# Enable the Omarchy first-boot setup service when the unit was installed
if [[ -f /usr/lib/systemd/system/omarchy-firstboot.service ]]; then
    systemctl enable omarchy-firstboot.service
fi

echo "::endgroup::"

echo "Services configured."
