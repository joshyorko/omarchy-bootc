#!/usr/bin/bash
# shellcheck shell=bash
#
# 10-base.sh — Install core system packages for omarchy-bootc
#
# Runs at OCI build time via:
#   RUN --mount=type=bind,from=ctx ... /ctx/build/10-base.sh
#
# Package manager: pacman  (not dnf5, rpm-ostree, or any Fedora tooling)

set -eoux pipefail

echo "::group:: Install base packages"

# Read package list — strip comments and blank lines
mapfile -t BASE_PKGS < <(grep -v '^#' /ctx/custom/packages/base.packages | grep -v '^$')

if [[ ${#BASE_PKGS[@]} -gt 0 ]]; then
    pacman -S --noconfirm --needed "${BASE_PKGS[@]}"
fi

echo "::endgroup::"

echo "::group:: Install systemd units"

# Copy project-supplied systemd units into the image
if [[ -d /ctx/systemd/system ]]; then
    mkdir -p /usr/lib/systemd/system
    # Use find+cp to avoid glob failures on empty directories
    find /ctx/systemd/system -maxdepth 1 -type f -name '*.service' \
        -exec cp -v {} /usr/lib/systemd/system/ \;
fi

echo "::endgroup::"

echo "::group:: Stage first-boot helper"

# Stage the first-boot script so 30-services.sh can enable it
if [[ -d /ctx/custom/first-boot ]]; then
    mkdir -p /usr/lib/omarchy
    cp -r /ctx/custom/first-boot/. /usr/lib/omarchy/
    chmod +x /usr/lib/omarchy/*.sh 2>/dev/null || true
fi

echo "::endgroup::"

echo "Base build complete."
