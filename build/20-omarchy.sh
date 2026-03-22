#!/usr/bin/bash
# shellcheck shell=bash
#
# 20-omarchy.sh — Install minimal Hyprland/Omarchy session packages
#
# This layer intentionally installs a SMALL baseline set from
# custom/packages/omarchy.packages to keep the proof-of-concept credible while
# avoiding false claims of full Omarchy parity.

set -eoux pipefail

echo "::group:: Install Omarchy / Hyprland packages"

# Read package list — strip comments and blank lines
mapfile -t OMARCHY_PKGS < <(grep -v '^#' /ctx/custom/packages/omarchy.packages | grep -v '^$')

if [[ ${#OMARCHY_PKGS[@]} -gt 0 ]]; then
    pacman -S --noconfirm --needed "${OMARCHY_PKGS[@]}"
else
    echo "ERROR: custom/packages/omarchy.packages is empty after filtering."
    echo "Populate a minimal package set or explicitly document why this layer is disabled."
    exit 1
fi

echo "::endgroup::"

echo "::group:: Stage Hyprland config skeleton"

# Copy Hyprland config placeholders to a system-wide location.
# First-boot may copy this to the first non-system user's home as a starter.
if [[ -d /ctx/custom/hypr ]]; then
    mkdir -p /usr/share/omarchy/hypr
    cp -r /ctx/custom/hypr/. /usr/share/omarchy/hypr/
fi

echo "::endgroup::"

echo "Omarchy layer complete (minimal baseline)."
