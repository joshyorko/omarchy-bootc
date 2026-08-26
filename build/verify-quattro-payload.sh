#!/usr/bin/env bash
set -euo pipefail

OMARCHY_VERSION="${OMARCHY_VERSION:-4.0.1-1}"
PROVENANCE_DIR="/usr/share/omarchy-bootc"
PROVENANCE_REPORT="${PROVENANCE_DIR}/package-provenance.txt"

declare -A EXPECTED_OWNERS=(
    [/usr/bin/omarchy]=omarchy
    [/usr/bin/omarchy-menu]=omarchy
    [/usr/bin/omarchy-theme-list]=omarchy
    [/usr/share/omarchy/shell/Commons/Border.qml]=omarchy
    [/usr/share/omarchy/themes/catppuccin/colors.toml]=omarchy
    [/etc/skel/.config/hypr/hyprland.lua]=omarchy-settings
    [/usr/share/sddm/themes/omarchy/Main.qml]=omarchy-settings
    [/usr/share/omarchy/default/wayland-sessions/omarchy.desktop]=omarchy-settings
)

for package in omarchy omarchy-settings; do
    installed_version="$(pacman -Q "${package}" | awk '{ print $2 }')"
    if [[ "${installed_version}" != "${OMARCHY_VERSION}" ]]; then
        printf 'Expected %s %s, found %s\n' \
            "${package}" "${OMARCHY_VERSION}" "${installed_version}" >&2
        exit 1
    fi
done

canonical_session=/usr/share/omarchy/default/wayland-sessions/omarchy.desktop
projected_session=/usr/share/wayland-sessions/omarchy.desktop
cmp --silent "${canonical_session}" "${projected_session}"

install -d -m 0755 "${PROVENANCE_DIR}"
{
    printf 'Official Omarchy Quattro package provenance\n'
    printf 'Expected package version: %s\n\n' "${OMARCHY_VERSION}"
    pacman -Qii omarchy omarchy-settings omarchy-keyring
    printf '\nRepresentative desktop payload ownership:\n'
} >"${PROVENANCE_REPORT}"

for path in "${!EXPECTED_OWNERS[@]}"; do
    expected_owner="${EXPECTED_OWNERS[${path}]}"
    actual_owner="$(pacman -Qoq "${path}")"
    if [[ "${actual_owner}" != "${expected_owner}" ]]; then
        printf 'Expected %s to be owned by %s, found %s\n' \
            "${path}" "${expected_owner}" "${actual_owner}" >&2
        exit 1
    fi
    printf '%s -> %s\n' "${path}" "${actual_owner}" >>"${PROVENANCE_REPORT}"
done

printf '\nbootc projection exception: %s -> %s (byte-identical)\n' \
    "${canonical_session}" "${projected_session}" >>"${PROVENANCE_REPORT}"

pacman -Qkk omarchy >>"${PROVENANCE_REPORT}"
settings_audit="$(pacman -Qkk omarchy-settings 2>&1 || true)"
printf '%s\n' "${settings_audit}" >>"${PROVENANCE_REPORT}"
unexpected_drift="$(printf '%s\n' "${settings_audit}" \
    | grep '^warning:' \
    | grep -Ev '^warning: omarchy-settings: /usr/local \(File type mismatch\)$|^warning: omarchy-settings: /usr/local/share \(No such file or directory\)$|^warning: omarchy-settings: /usr/local/share/wayland-sessions \(No such file or directory\)$|^warning: omarchy-settings: /usr/local/share/wayland-sessions/omarchy.desktop \(No such file or directory\)$' \
    || true)"
if [[ -n "${unexpected_drift}" ]]; then
    printf 'Unexpected omarchy-settings path drift:\n%s\n' "${unexpected_drift}" >&2
    exit 1
fi
