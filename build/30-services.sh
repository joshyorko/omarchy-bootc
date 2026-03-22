#!/usr/bin/bash
# shellcheck shell=bash
#
# 30-services.sh — Enable / disable systemd services

set -eoux pipefail

echo "::group:: Enable systemd services"

# Core networking
systemctl enable NetworkManager.service   || true
systemctl enable systemd-resolved.service || true

# Login/session path for VM POC
systemctl enable greetd.service || true

# Convenience features for test VMs
systemctl enable sshd.service || true
systemctl enable podman.socket || true

echo "::endgroup::"

echo "::group:: Enable first-boot service"

if [[ -f /usr/lib/systemd/system/omarchy-firstboot.service ]]; then
    systemctl enable omarchy-firstboot.service
fi

echo "::endgroup::"

echo "Services configured."
