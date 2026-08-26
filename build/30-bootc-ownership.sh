#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /ctx/build/lib/bootc-initramfs.sh

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

install -D -m 0644 /dev/stdin \
    /usr/lib/dracut/dracut.conf.d/40-bootc-required-modules.conf <<'EOF'
# bootc v1.16.10 baseimage/dracut/usr/lib/dracut.conf.d/10-bootc-base.conf
# requires both modules. This final-layer correction leaves the pinned
# Bootcrew construction snapshot unmodified.
add_dracutmodules+=" ostree bootc "
EOF

latest_kver="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)"
dracut --force "/usr/lib/modules/${latest_kver}/initramfs.img"
lsinitrd -m "/usr/lib/modules/${latest_kver}/initramfs.img" \
    > /usr/share/omarchy-bootc/initramfs-modules.txt
lsinitrd "/usr/lib/modules/${latest_kver}/initramfs.img" \
    > /usr/share/omarchy-bootc/initramfs-contents.txt
verify_bootc_initramfs_reports \
    /usr/share/omarchy-bootc/initramfs-modules.txt \
    /usr/share/omarchy-bootc/initramfs-contents.txt

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
