#!/usr/bin/env bash
set -euo pipefail

kind="${1:?usage: local-qemu.sh iso|qcow2|raw IMAGE [RAM] [DISK_SIZE]}"
image="$(realpath -e -- "${2:?specify an ISO or disk image}")"
ram="${3:-4G}"
size="${4:-32G}"
for command in qemu-system-x86_64 qemu-img; do
    command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done
[[ -f "$image" ]] || { echo "VM input must be a regular file" >&2; exit 1; }
case "$kind" in
    iso|qcow2|raw) ;;
    *) echo "Unsupported VM input: $kind" >&2; exit 2 ;;
esac

# Use matched firmware and variable images, including Fedora's QEMU package.
firmware="${OMARCHY_OVMF_CODE:-}"
vars="${OMARCHY_OVMF_VARS:-}"
if [[ -z "$firmware" && -z "$vars" ]]; then
    while read -r code template; do
        if [[ -r "$code" && -r "$template" ]]; then
            firmware="$code"
            vars="$template"
            break
        fi
    done <<'FIRMWARE'
/usr/share/qemu/edk2-x86_64-code.fd /usr/share/qemu/edk2-i386-vars.fd
/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
/usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_VARS.fd
/usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_VARS.fd
/usr/share/edk2/x64/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_VARS.fd
FIRMWARE
fi
[[ -f "$firmware" && -f "$vars" && -r "$firmware" && -r "$vars" ]] || {
    echo "A matched OVMF CODE/VARS pair is required. Set OMARCHY_OVMF_CODE and OMARCHY_OVMF_VARS." >&2
    exit 1
}

accel="${OMARCHY_VM_ACCEL:-auto}"
if [[ "$accel" == auto ]]; then
    accel=tcg
    if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then accel=kvm; fi
fi
case "$accel" in
    kvm) cpu=host ;;
    tcg) cpu=max ;;
    *) echo "OMARCHY_VM_ACCEL must be auto, kvm or tcg" >&2; exit 2 ;;
esac

output="${OMARCHY_VM_ARTIFACT_DIR:-output/local-vm}"
mkdir -p -- "$output"
run="$(mktemp -d "$(realpath -- "$output")/vm.XXXXXXXX")"
cp -- "$vars" "$run/vars.fd"
# QEMU's -drive parser reserves commas. Double them in filenames.
drive_path() { printf '%s' "${1//,/,,}"; }
disk_args=()
case "$kind" in
    iso)
        qemu-img create -q -f qcow2 "$run/installed.qcow2" "$size"
        sha256sum -- "$image" >"$run/installer.sha256"
        # QEMU drive suboptions are one comma-delimited argument.
        # shellcheck disable=SC2054
        disk_args=(-drive "if=virtio,format=qcow2,file=$(drive_path "$run/installed.qcow2")"
                   -drive "media=cdrom,format=raw,readonly=on,file=$(drive_path "$image")"
                   -boot once=d,menu=on)
        ;;
    *) disk_args=(-drive "if=virtio,format=$kind,snapshot=on,file=$(drive_path "$image")" -boot menu=on) ;;
esac

display_args=(-display none -vnc "unix:$run/display.sock")
if [[ "${OMARCHY_VM_DISPLAY:-vnc}" == gtk ]]; then
    display_args=(-display gtk)
fi
printf 'input=%s\nkind=%s\naccel=%s\nqmp=%s\n' "$image" "$kind" "$accel" "$run/qmp.sock" | tee "$run/vm.txt"
printf 'Running disposable QEMU guest. Capture from another shell with:\n  just capture-vm-screen %q %q\n' "$run/qmp.sock" "$run/screen.png"
TMPDIR="$run" qemu-system-x86_64 \
    -machine q35 -accel "$accel" -cpu "$cpu" -smp 2 -m "$ram" \
    -drive "if=pflash,format=raw,readonly=on,file=$(drive_path "$firmware")" \
    -drive "if=pflash,format=raw,file=$(drive_path "$run/vars.fd")" \
    "${display_args[@]}" -device virtio-vga -device qemu-xhci -device usb-tablet \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -serial "file:$run/serial.log" -monitor none \
    -qmp "unix:$run/qmp.sock,server=on,wait=off" "${disk_args[@]}"
