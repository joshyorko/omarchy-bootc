#!/usr/bin/bash
# shellcheck shell=bash
#
# 20-omarchy.sh — Install minimal Hyprland/Omarchy session packages

set -eoux pipefail

echo "::group:: Install Omarchy / Hyprland packages"

mapfile -t OMARCHY_PKGS < <(grep -v '^#' /ctx/custom/packages/omarchy.packages | grep -v '^$')

if [[ ${#OMARCHY_PKGS[@]} -gt 0 ]]; then
    pacman -S --noconfirm --needed "${OMARCHY_PKGS[@]}"
else
    echo "ERROR: custom/packages/omarchy.packages is empty after filtering."
    exit 1
fi

echo "::endgroup::"

echo "::group:: Stage Hyprland + greetd config"

if [[ -d /ctx/custom/hypr ]]; then
    mkdir -p /usr/share/omarchy/hypr
    cp -r /ctx/custom/hypr/. /usr/share/omarchy/hypr/
fi

if [[ -d /ctx/custom/skel ]]; then
    mkdir -p /usr/share/omarchy/skel
    cp -r /ctx/custom/skel/. /usr/share/omarchy/skel/
fi

# Install project-managed greetd config for explicit VM login path.
if [[ -f /ctx/custom/greetd/config.toml ]]; then
    mkdir -p /etc/greetd
    cp -v /ctx/custom/greetd/config.toml /etc/greetd/config.toml
fi

echo "::endgroup::"

echo "Omarchy layer complete (minimal baseline)."
