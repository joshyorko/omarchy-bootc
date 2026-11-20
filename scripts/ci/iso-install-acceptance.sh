#!/usr/bin/env bash
# Remote command strings expand only inside the disposable guest.
# shellcheck disable=SC2016
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true ]] || { echo 'ISO disk installation is GitHub-hosted CI only' >&2; exit 2; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
iso=$(realpath "${1:?Usage: iso-install-acceptance.sh ISO}")
[[ -f $iso ]]
: "${RUNNER_TEMP:?}" "${CI_ARTIFACT_DIR:?}" "${INSTALL_IMAGE_REF:?}" "${INSTALL_SOURCE_SHA:?}"
[[ $INSTALL_IMAGE_REF =~ ^ghcr.io/joshyorko/omarchy-bootc@sha256:[a-f0-9]{64}$ ]]
[[ $INSTALL_SOURCE_SHA =~ ^[a-f0-9]{40}$ ]]
expected=${INSTALL_IMAGE_REF##*@}
df -Pk "$RUNNER_TEMP" | awk 'NR==2 {exit !($4 >= 25*1024*1024)}'
mkdir -p "$CI_ARTIFACT_DIR/screenshots"
work=$(mktemp -d "$RUNNER_TEMP/omarchy-iso-install.XXXXXXXX")
disk="$work/disk.qcow2"
qmp="$work/qmp.sock"
pidfile="$work/qemu.pid"
http_pid=''
cleanup_qemu() {
    local pid
    if [[ -s $pidfile ]]; then
        pid=$(cat "$pidfile")
        if [[ $pid =~ ^[0-9]+$ ]] && sudo -n cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | grep -Fq -- "$disk"; then
            sudo -n kill "$pid" || true
        fi
    fi
}
capture() { sudo -n python3 "$script_dir/capture-vm-screen.py" "$qmp" "$CI_ARTIFACT_DIR/screenshots/$1.png"; }
cleanup() {
    local status=$?
    if ((status != 0)); then capture failure || true; fi
    cleanup_qemu
    if [[ -n $http_pid && -r /proc/$http_pid/cmdline ]] && tr '\0' ' ' <"/proc/$http_pid/cmdline" | grep -Fq -- "$work/web"; then
        kill "$http_pid" 2>/dev/null || true
    fi
    # Preserve failure evidence, never upload the ISO or whole guest disks.
    for name in live-serial.log installed-serial.log; do
        [[ ! -f "$work/$name" ]] || cp "$work/$name" "$CI_ARTIFACT_DIR/$name"
    done
    exit "$status"
}
trap cleanup EXIT
[[ -c /dev/kvm ]] && sudo -n test -r /dev/kvm && sudo -n test -w /dev/kvm
printf 'kvm\n' >"$CI_ARTIFACT_DIR/accelerator.txt"
# Titanoboa's exact pinned layout/boot arguments, with the ISO still attached.
# This boots the ISO live root and Anaconda; it never calls bootc install directly.
xorriso -osirrox on -indev "$iso" -extract /boot/vmlinuz "$work/vmlinuz" \
    -extract /boot/initramfs.img "$work/initramfs.img" >"$CI_ARTIFACT_DIR/iso-extract.log" 2>&1
code=/usr/share/OVMF/OVMF_CODE_4M.fd
vars=/usr/share/OVMF/OVMF_VARS_4M.fd
[[ -f $code && -f $vars ]]
cp "$vars" "$work/vars.fd"
qemu-img create -f qcow2 "$disk" 64G
password=omarchyci2026 # Disposable account only; never a workstation credential.
password_hash=$(openssl passwd -6 -salt omarchyci "$password")
mkdir "$work/web"
cat >"$work/web/install.ks" <<EOF
graphical
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --device=link --activate --hostname=omarchy-iso-ci
rootpw --lock
user --name=omarchyci --groups=wheel --password=$password_hash --iscrypted
zerombr
clearpart --all --initlabel --drives=vda
autopart --type=btrfs
bootloader --location=mbr
ostreecontainer --url=$INSTALL_IMAGE_REF --transport=containers-storage
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%post --erroronfail
systemctl enable sshd.service
ufw allow 22/tcp
printf 'OMARCHY_ISO_INSTALL_COMPLETE\n' >/dev/ttyS0
%end
%onerror
cat /tmp/anaconda.log /tmp/program.log /tmp/storage.log >/dev/ttyS0 2>&1 || true
%end
reboot --eject
EOF
python3 -m http.server 18763 --bind 127.0.0.1 --directory "$work/web" >"$CI_ARTIFACT_DIR/kickstart-http.log" 2>&1 &
http_pid=$!
common=(-machine 'q35,accel=kvm' -cpu host -smp 4 -m 6144
    -drive "if=pflash,format=raw,readonly=on,file=$code"
    -drive "if=pflash,format=raw,file=$work/vars.fd"
    -drive "file=$disk,if=virtio,format=qcow2"
    -netdev 'user,id=net0,hostfwd=tcp:127.0.0.1:2239-:22' -device 'virtio-net-pci,netdev=net0'
    -vga virtio -display none -qmp "unix:$qmp,server=on,wait=off" -pidfile "$pidfile" -daemonize)
sudo -n qemu-system-x86_64 "${common[@]}" \
    -drive "file=$iso,media=cdrom,readonly=on" \
    -kernel "$work/vmlinuz" -initrd "$work/initramfs.img" \
    -append 'root=live:CDLABEL=titanoboa_boot enforcing=0 rd.live.image inst.ks=http://10.0.2.2:18763/install.ks console=ttyS0' \
    -no-reboot -serial "file:$work/live-serial.log"
deadline=$((SECONDS+3600))
next_capture=$((SECONDS+30))
while ((SECONDS < deadline)); do
    if grep -Fq OMARCHY_ISO_INSTALL_COMPLETE "$work/live-serial.log"; then break; fi
    sudo -n kill -0 "$(cat "$pidfile")" 2>/dev/null || { echo 'Installer exited before completion' >&2; exit 1; }
    if ((SECONDS >= next_capture)); then capture installer-last-observed; next_capture=$((SECONDS+60)); fi
    sleep 10
done
grep -Fq OMARCHY_ISO_INSTALL_COMPLETE "$work/live-serial.log"
[[ -s "$CI_ARTIFACT_DIR/screenshots/installer-last-observed.png" ]]
cleanup_qemu
sleep 3
rm -f "$qmp" "$pidfile"
# The installed phase has no CD, kernel/initrd injection or acceptance overlay.
sudo -n qemu-system-x86_64 "${common[@]}" -serial "file:$work/installed-serial.log"
ssh_args=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -p 2239)
guest() { sshpass -p "$password" ssh "${ssh_args[@]}" omarchyci@127.0.0.1 "$@"; }
deadline=$((SECONDS+600))
until guest true; do ((SECONDS < deadline)); sleep 5; done
deadline=$((SECONDS+180))
until guest 'pgrep -x "sddm-greeter.*" >/dev/null && ! pgrep -u "$(id -u)" -x Hyprland'; do
    ((SECONDS < deadline)); sleep 3
done
capture installed-greeter
sudo -n python3 "$script_dir/qmp-login.py" "$qmp" "$password"
deadline=$((SECONDS+240))
until guest 'pgrep -u "$(id -u)" -x Hyprland >/dev/null && pgrep -u "$(id -u)" -x quickshell >/dev/null'; do
    ((SECONDS < deadline)); sleep 3
done
guest 'sudo -n /usr/libexec/omarchy-bootc-status' >"$CI_ARTIFACT_DIR/installed-bootc-status.json"
jq -e --arg digest "$expected" '.status.booted.image.imageDigest == $digest and .status.booted.composefs != null and .spec.image.image == "ghcr.io/joshyorko/omarchy-bootc:testing"' \
    "$CI_ARTIFACT_DIR/installed-bootc-status.json" >/dev/null
guest 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; export HYPRLAND_INSTANCE_SIGNATURE="$(find "$XDG_RUNTIME_DIR/hypr" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | head -n1)"; /usr/local/bin/omarchy plugin list --json' \
    >"$CI_ARTIFACT_DIR/installed-plugins.json"
jq -e 'any(.[]; .id == "omarchy.clock" and .firstParty == true)' "$CI_ARTIFACT_DIR/installed-plugins.json" >/dev/null
capture installed-desktop
guest 'journalctl --user -b --no-pager' >"$CI_ARTIFACT_DIR/installed-user-journal.log"
jq -n --arg source "$INSTALL_SOURCE_SHA" --arg image "$INSTALL_IMAGE_REF" \
    '{source_sha:$source,install_image_ref:$image,scope:"Anaconda ISO blank-disk installation, disk-only KVM boot and password login",status:"installed-guest-checks-passed",visual_review:"required",installer_parity:"not-claimed"}' \
    >"$CI_ARTIFACT_DIR/iso-install.receipt.json"
