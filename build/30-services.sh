#!/usr/bin/bash
# shellcheck shell=bash
#
# 30-services.sh — Enable / disable systemd services
#
# Runs after package installation. Keep this list conservative and aligned with
# actually installed packages. This POC intentionally avoids claiming a complete
# desktop/login-manager story yet.

set -eoux pipefail

echo "::group:: Enable systemd services"

# Core networking
systemctl enable NetworkManager.service   || true
systemctl enable systemd-resolved.service || true

# Remote access + container socket are convenience features for test VMs.
systemctl enable sshd.service || true
systemctl enable podman.socket || true

echo "::endgroup::"

echo "::group:: Enable first-boot service"

# Root one-shot setup service. User-session setup remains deferred.
if [[ -f /usr/lib/systemd/system/omarchy-firstboot.service ]]; then
    systemctl enable omarchy-firstboot.service
fi

echo "::endgroup::"

echo "Services configured."
