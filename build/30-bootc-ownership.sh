#!/usr/bin/env bash
set -euo pipefail

HOOK_INVENTORY=/ctx/build/bootc-disabled-hooks.txt
BOOTC_CONFLICTING_UNITS=(
    limine-snapper-sync.service
    snapper-cleanup.timer
    snapper-timeline.timer
)

export OMARCHY_PATH=/usr/share/omarchy
export OMARCHY_INSTALL=/usr/share/omarchy/install
bash "${OMARCHY_INSTALL}/config/enable-services.sh"
bash "${OMARCHY_INSTALL}/login/sddm.sh"

for unit in "${BOOTC_CONFLICTING_UNITS[@]}"; do
    systemctl disable "${unit}" >/dev/null 2>&1 || true
    systemctl mask "${unit}"
    [[ "$(systemctl is-enabled "${unit}")" == "masked" ]]
done

while IFS= read -r hook_name; do
    hook="/usr/share/omarchy-bootc/pacman-hooks/${hook_name}"
    [[ -f "${hook}" ]]
    grep -Fq 'Target = __omarchy_bootc_never_matches__' "${hook}"
done <"${HOOK_INVENTORY}"

latest_kver="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)"
dracut --force "/usr/lib/modules/${latest_kver}/initramfs.img"
lsinitrd "/usr/lib/modules/${latest_kver}/initramfs.img" > /usr/share/omarchy-bootc/initramfs-contents.txt
grep -Fq 'bootc' /usr/share/omarchy-bootc/initramfs-contents.txt

{
    pacman -Q kernel-modules-hook
    systemctl is-enabled linux-modules-cleanup.service
} > /usr/share/omarchy-bootc/kernel-modules-hook-audit.txt

# Package hooks generated runtime/cache state that cannot be part of a bootc
# deployment. Fontconfig and systemd recreate these on the deployed /var,/run.
find /run -mindepth 1 -maxdepth 1 \
    ! -name .containerenv \
    ! -name host \
    -exec rm -rf -- {} +
find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
find /var -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
