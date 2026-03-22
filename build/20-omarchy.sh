#!/usr/bin/bash
# shellcheck shell=bash
#
# 20-omarchy.sh — Install Hyprland and Omarchy-specific packages
#
# This script is intentionally left as a placeholder for the first
# working VM image.  Uncomment and populate the package list in
# custom/packages/omarchy.packages to activate.

set -eoux pipefail

echo "::group:: Install Omarchy / Hyprland packages"

# Read package list — strip comments and blank lines
mapfile -t OMARCHY_PKGS < <(grep -v '^#' /ctx/custom/packages/omarchy.packages | grep -v '^$')

if [[ ${#OMARCHY_PKGS[@]} -gt 0 ]]; then
    pacman -S --noconfirm --needed "${OMARCHY_PKGS[@]}"
else
    echo "  (no packages listed — skipping)"
fi

echo "::endgroup::"

echo "::group:: Stage Hyprland config skeleton"

# Copy Hyprland config placeholders to a system-wide location.
# The first-boot script will offer to deploy them to ~/.config/hypr/.
if [[ -d /ctx/custom/hypr ]]; then
    mkdir -p /usr/share/omarchy/hypr
    cp -r /ctx/custom/hypr/. /usr/share/omarchy/hypr/
fi

echo "::endgroup::"

echo "Omarchy build complete."
