#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /ctx/build/lib/quattro-packages.sh

OMARCHY_VERSION="4.0.1-1"
OMARCHY_BASE_MANIFEST="/usr/share/omarchy/install/omarchy-base.packages"
OMARCHY_OTHER_MANIFEST="/usr/share/omarchy/install/omarchy-other.packages"
REPOSITORY_CONFIG="/ctx/custom/pacman/quattro-repositories.conf"
OPTIONAL_REPOSITORY_CONFIG="/ctx/custom/pacman/quattro-optional-resolver.conf"
HOOK_INVENTORY="/ctx/build/bootc-disabled-hooks.txt"
BOOTC_HOOK_DIR="/usr/share/omarchy-bootc/pacman-hooks"

# Preserve Bootcrew's bootc-specific pacman options and relocated database/cache
# paths while replacing only the repository sections with Quattro's topology.
bash /ctx/build/configure-quattro-repositories.sh /etc/pacman.conf "${REPOSITORY_CONFIG}"

# Pacman gives later HookDir entries precedence by filename. Install valid,
# never-triggering hooks under the exact evidenced names so official package
# files remain intact but cannot act on bootc-owned surfaces.
install -d -m 0755 "${BOOTC_HOOK_DIR}"
while IFS= read -r hook_name; do
    [[ -n "${hook_name}" ]]
    cat >"${BOOTC_HOOK_DIR}/${hook_name}" <<'EOF'
[Trigger]
Operation = Install
Type = Package
Target = __omarchy_bootc_never_matches__

[Action]
Description = bootc owns deployment and initramfs for this image
When = PostTransaction
Exec = /usr/bin/true
EOF
done <"${HOOK_INVENTORY}"
sed -i "/^\[options\]$/a HookDir = ${BOOTC_HOOK_DIR}" /etc/pacman.conf

pacman-key --init
pacman-key --populate archlinux
pacman -Syyu --noconfirm
pacman -S --noconfirm --needed omarchy-keyring
pacman-key --populate omarchy

# Bootcrew maps /usr/local to mutable /var/usrlocal. Pacman cannot install a
# package that owns /usr/local while the path is a symlink, so materialize it
# only for the official transaction and restore the bootc layout afterward.
[[ -L /usr/local ]]
usrlocal_target="$(readlink /usr/local)"
[[ "${usrlocal_target}" == "../var/usrlocal" ]]
rm /usr/local
install -d -m 0755 /usr/local

pacman -S --noconfirm --needed omarchy-settings omarchy

while IFS= read -r hook_name; do
    [[ -f "${BOOTC_HOOK_DIR}/${hook_name}" ]]
    grep -Fq 'Target = __omarchy_bootc_never_matches__' "${BOOTC_HOOK_DIR}/${hook_name}"
done <"${HOOK_INVENTORY}"

[[ "$(pacman -Q omarchy | awk '{ print $2 }')" == "${OMARCHY_VERSION}" ]]
[[ "$(pacman -Q omarchy-settings | awk '{ print $2 }')" == "${OMARCHY_VERSION}" ]]

mapfile -t base_packages < <(read_quattro_package_manifest "${OMARCHY_BASE_MANIFEST}")
mapfile -t other_packages < <(read_quattro_package_manifest "${OMARCHY_OTHER_MANIFEST}")

[[ ${#base_packages[@]} -gt 0 ]]
[[ ${#other_packages[@]} -gt 0 ]]

pacman -S --noconfirm --needed "${base_packages[@]}"

# The optional manifest contains mutually exclusive hardware packages. Resolve
# each dependency graph and retain the result without installing it wholesale.
# T2 packages use the supplemental repository shipped by the pinned official
# ISO, but that repository is applied only to this resolver copy so the proven
# Omarchy-stable foundation topology remains unchanged.
install -d -m 0755 /usr/share/omarchy-bootc
optional_report=/usr/share/omarchy-bootc/optional-package-resolvability.txt
optional_pacman_config=/tmp/quattro-optional-resolver.conf
cp /etc/pacman.conf "${optional_pacman_config}"
printf '\n' >>"${optional_pacman_config}"
cat "${OPTIONAL_REPOSITORY_CONFIG}" >>"${optional_pacman_config}"
pacman --config "${optional_pacman_config}" -Sy --noconfirm
: >"${optional_report}"
for package in "${other_packages[@]}"; do
    if resolution="$(pacman --config "${optional_pacman_config}" \
        -Sp --print-format '%n %v' "${package}" 2>&1)"; then
        printf 'resolvable %s\n%s\n' "${package}" "${resolution}" >>"${optional_report}"
    else
        printf 'unresolved %s\n%s\n' "${package}" "${resolution}" >>"${optional_report}"
    fi
done
verify_optional_resolution_report "${optional_report}"
optional_database_path="$(pacman-conf \
    --config "${optional_pacman_config}" DBPath)"
remove_optional_repository_database \
    "${optional_database_path}" \
    arch-mact2

for required in \
    /usr/bin/omarchy \
    /usr/bin/omarchy-menu \
    /usr/bin/omarchy-theme-list \
    /usr/share/omarchy/shell \
    /usr/share/omarchy/themes \
    /usr/share/sddm/themes/omarchy \
    /usr/local/share/wayland-sessions/omarchy.desktop; do
    [[ -e "${required}" ]]
done

mapfile -t usrlocal_files < <(find /usr/local -type f -print | sort)
[[ ${#usrlocal_files[@]} -eq 2 ]]
[[ "${usrlocal_files[0]}" == "/usr/local/bin/mkinitcpio" ]]
[[ "${usrlocal_files[1]}" == "/usr/local/share/wayland-sessions/omarchy.desktop" ]]
canonical_session=/usr/share/omarchy/default/wayland-sessions/omarchy.desktop
projected_session=/usr/share/wayland-sessions/omarchy.desktop
cmp --silent "${usrlocal_files[1]}" "${canonical_session}"
install -Dm644 "${canonical_session}" "${projected_session}"
cmp --silent "${projected_session}" "${canonical_session}"
# shellcheck disable=SC2114
rm -rf /usr/local
ln -s "${usrlocal_target}" /usr/local

pacman -Scc --noconfirm
