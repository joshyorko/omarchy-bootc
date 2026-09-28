#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root_dir}/build/acceptance-dependencies.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

expect_failure() {
    local expected="$1" status=0
    shift
    ("$@") >"$fixture/output" 2>&1 || status=$?
    [[ $status != 0 ]] || { echo 'unexpected dependency success' >&2; exit 1; }
    grep -Fq -- "$expected" "$fixture/output"
}

expect_failure 'Usage:' main
expect_failure 'Usage:' main unknown
expect_failure 'Usage:' main final extra

# A package name in a stale manifest is not a runtime executable. Isolate
# discovery from the host's sudo installation without mocking command lookup.
mkdir "$fixture/bin"
printf 'sudo\n' >"$fixture/base.packages"
host_path="$PATH"
(
    export PATH="$fixture/bin"
    require_immutable_command sudo
) >"$fixture/output" 2>&1 && { echo 'missing sudo accepted' >&2; exit 1; }
grep -Fq 'missing command: sudo' "$fixture/output"

printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/sudo"
expect_failure 'missing executable:' require_executable "$fixture/bin/sudo"
chmod 0755 "$fixture/bin/sudo"
# This fragment runs under `bash -c`; preserve the remote expansion boundary.
# shellcheck disable=SC2016
expect_failure 'command is not image-owned:' env \
    PATH="$fixture/bin:$host_path" bash -c 'source "$1"; require_immutable_command sudo' \
    bash "$root_dir/build/acceptance-dependencies.sh"
rm "$fixture/bin/sudo"
ln -s "$fixture/absent" "$fixture/bin/sudo"
expect_failure 'missing executable:' require_executable "$fixture/bin/sudo"
# Symlinks to genuine image binaries remain valid (Arch /bin compatibility).
require_immutable_command bash

cat >"$fixture/sudoers" <<'EOF'
# Example only: %wheel ALL=(ALL:ALL) NOPASSWD: ALL
%wheel ALL=(ALL:ALL) PASSWD: ALL
ALL ALL=(root) NOPASSWD: /usr/bin/asdcontrol
EOF
require_bounded_sudo_policy "$fixture/sudoers"
printf '%s\n' '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >"$fixture/sudoers"
expect_failure 'unrestricted passwordless sudo' require_bounded_sudo_policy "$fixture/sudoers"
# This fixture deliberately contains a literal backslash-quote sequence.
# shellcheck disable=SC1003
printf '%s\n' 'omarchy ALL=(root) NOPASSWD: /usr/bin/true, \' ' ALL' >"$fixture/sudoers"
expect_failure 'unrestricted passwordless sudo' require_bounded_sudo_policy "$fixture/sudoers"
printf '%s\n' \
    '%wheel ALL=(root) NOPASSWD: /usr/libexec/omarchy-bootc-status ""' \
    '%wheel ALL=(root) NOPASSWD: /usr/libexec/omarchy-bootc-clear-transaction ""' \
    >"$fixture/scoped-sudoers"
require_scoped_sudo_command /usr/libexec/omarchy-bootc-status "$fixture"
require_scoped_sudo_command /usr/libexec/omarchy-bootc-clear-transaction "$fixture"
expect_failure 'missing scoped sudo command' \
    require_scoped_sudo_command /usr/libexec/omarchy-bootc-status "$fixture/absent"


# Package metadata is isolated; payload files and offline systemd enablement
# use real filesystem state. Regressions reject incompatible or unowned payloads.
pacman() {
    case "$1" in
        -Q) [[ -f "$fixture/packages/$2" ]] && printf '%s %s\n' "$2" "$(cat "$fixture/packages/$2")" ;;
        -Qqo) [[ -f "$2.owner" ]] && cat "$2.owner" ;;
        *) return 2 ;;
    esac
}
mkdir -p "$fixture/packages" "$fixture/modules/7.2.3-arch1-3/build/include/config"
printf 'linux\n' >"$fixture/kernel-package"
printf '7.2.3.arch1-3\n' >"$fixture/packages/linux"
cp "$fixture/packages/linux" "$fixture/packages/linux-headers"
module_dir="$fixture/modules/7.2.3-arch1-3"
printf 'linux\n' >"$module_dir/pkgbase"
printf 'kernel payload\n' >"$module_dir/vmlinuz"
printf 'linux\n' >"$module_dir/pkgbase.owner"
printf 'linux\n' >"$module_dir/vmlinuz.owner"
printf '7.2.3-arch1-3\n' >"$module_dir/build/include/config/kernel.release"
printf 'linux-headers\n' >"$module_dir/build/include/config/kernel.release.owner"
require_kernel_headers "$fixture/kernel-package" "$fixture/modules"
printf '7.2.4.arch1-1\n' >"$fixture/packages/linux-headers"
expect_failure 'kernel/header package version mismatch' require_kernel_headers "$fixture/kernel-package" "$fixture/modules"
cp "$fixture/packages/linux" "$fixture/packages/linux-headers"
printf '7.2.4-arch1-1\n' >"$module_dir/build/include/config/kernel.release"
expect_failure 'kernel/header release mismatch' require_kernel_headers "$fixture/kernel-package" "$fixture/modules"
printf '7.2.3-arch1-3\n' >"$module_dir/build/include/config/kernel.release"
printf 'unrelated-headers\n' >"$module_dir/build/include/config/kernel.release.owner"
expect_failure 'kernel headers are not owned by linux-headers' require_kernel_headers "$fixture/kernel-package" "$fixture/modules"
printf 'linux-headers\n' >"$module_dir/build/include/config/kernel.release.owner"
rm "$fixture/packages/linux-headers"
expect_failure 'missing kernel headers: linux-headers' require_kernel_headers "$fixture/kernel-package" "$fixture/modules"
cp "$fixture/packages/linux" "$fixture/packages/linux-headers"
rm "$module_dir/vmlinuz"
expect_failure 'missing declared kernel image' require_kernel_headers "$fixture/kernel-package" "$fixture/modules"
printf 'kernel payload\n' >"$module_dir/vmlinuz"
printf 'linux-omarchy\n' >"$fixture/kernel-package"
expect_failure 'missing declared kernel: linux-omarchy' require_kernel_headers "$fixture/kernel-package" "$fixture/modules"
printf 'linux\n' >"$fixture/kernel-package"
mkdir "$fixture/empty-modules"
expect_failure 'expected one installed module tree' require_kernel_headers "$fixture/kernel-package" "$fixture/empty-modules"

service_root="$fixture/service-root"
mkdir -p "$service_root/usr/lib/systemd/system" "$service_root/usr/lib/systemd/user" \
    "$service_root/etc/systemd/system/multi-user.target.wants" "$service_root/etc/ufw"
for unit in cups.service avahi-daemon.service linux-modules-cleanup.service \
    docker.socket systemd-resolved.service NetworkManager.service \
    power-profiles-daemon.service sddm.service systemd-oomd.service ufw.service sshd.service; do
    printf '[Unit]\nDescription=Fixture\n[Install]\nWantedBy=multi-user.target\n' \
        >"$service_root/usr/lib/systemd/system/$unit"
    ln -s "/usr/lib/systemd/system/$unit" "$service_root/etc/systemd/system/multi-user.target.wants/$unit"
done
printf '[Service]\nExecStart=/usr/bin/pipewire-pulse\n' >"$service_root/usr/lib/systemd/user/pipewire-pulse.service"
printf 'pipewire-pulse\n' >"$service_root/usr/lib/systemd/user/pipewire-pulse.service.owner"
printf 'ENABLED=yes\n' >"$service_root/etc/ufw/ufw.conf"
# Keep the offline enablement test deterministic on hosts without systemd.
cat >"$fixture/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=/
if [[ ${1:-} == --root=* ]]; then
    root="${1#--root=}"
    shift
fi
[[ ${1:-} == is-enabled && $# == 2 ]] || exit 2
unit="$2"
[[ -L "$root/etc/systemd/system/multi-user.target.wants/$unit" ]] || exit 1
printf 'enabled\n'
EOF
chmod 0755 "$fixture/bin/systemctl"
PATH="$fixture/bin:$host_path" require_desktop_services "$service_root"
rm "$service_root/usr/lib/systemd/system/cups.service"
PATH="$fixture/bin:$host_path" expect_failure 'missing required service unit: cups.service' require_desktop_services "$service_root"
printf '[Unit]\nDescription=Fixture\n[Install]\nWantedBy=multi-user.target\n' \
    >"$service_root/usr/lib/systemd/system/cups.service"

rm "$service_root/etc/systemd/system/multi-user.target.wants/ufw.service"
PATH="$fixture/bin:$host_path" expect_failure 'required service is not enabled: ufw.service' require_desktop_services "$service_root"
ln -s /usr/lib/systemd/system/ufw.service "$service_root/etc/systemd/system/multi-user.target.wants/ufw.service"
printf 'ENABLED=no\n' >"$service_root/etc/ufw/ufw.conf"
PATH="$fixture/bin:$host_path" expect_failure 'UFW configuration is not enabled' require_desktop_services "$service_root"
printf 'ENABLED=yes\n' >"$service_root/etc/ufw/ufw.conf"
rm "$service_root/usr/lib/systemd/user/pipewire-pulse.service"
PATH="$fixture/bin:$host_path" expect_failure 'missing pipewire-pulse user service' require_desktop_services "$service_root"

printf 'acceptance dependency boundaries, kernel headers and desktop services passed\n'
