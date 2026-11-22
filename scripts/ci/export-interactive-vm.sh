#!/usr/bin/env bash
# Hosted-only, personal VM fixture; never a release image or installer ISO.
# Runner-owned logs/archives intentionally use unprivileged redirections.
# shellcheck disable=SC2024
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || { echo 'Hosted VM export only' >&2; exit 2; }
: "${RUNNER_TEMP:?}" "${GITHUB_WORKSPACE:?}"
source_sha=341dbb85351994fad83012e40c5bb894c96d1cb5
parent_digest=sha256:9e369b93c9784f7e805cd01951fab60fcff19e5c4bbe24c1737ef91d549bd56d
candidate="$RUNNER_TEMP/interactive-candidate"
out="$RUNNER_TEMP/interactive-vm"
work=$(mktemp -d "$RUNNER_TEMP/interactive-work.XXXXXXXX")
mkdir -p "$out" "$work/ctx/build"
pidfile="$work/qemu.pid"
cleanup() {
    if [[ -s $pidfile ]]; then
        pid=$(cat "$pidfile")
        if [[ $pid =~ ^[0-9]+$ ]] && sudo -n cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | grep -Fq -- "$work/test.qcow2"; then sudo -n kill "$pid" || true; fi
    fi
}
trap cleanup EXIT
df -Pk "$RUNNER_TEMP" | awk 'NR==2 {exit !($4 >= 30*1024*1024)}'
shopt -s nullglob
receipts=("$candidate"/*.receipt.json)
[[ ${#receipts[@]} == 1 ]]
receipt=${receipts[0]}
archive="$candidate/$(jq -er .archive "$receipt")"
python3 scripts/ci/verify-candidate-archive.py "$receipt" "$archive" "$source_sha" >"$out/archive-verification.json"
jq -e --arg digest "$parent_digest" '.manifest_digest==$digest' "$out/archive-verification.json" >/dev/null
jq -e --arg sha "$source_sha" --arg digest "$parent_digest" '.source_sha==$sha and .candidate.oci_manifest_digest==$digest and .acceptance.status=="passed" and .acceptance.lifecycle=="passed"' "$RUNNER_TEMP/accepted/accepted-candidate.receipt.json" >/dev/null
cp "$RUNNER_TEMP/accepted/accepted-candidate.receipt.json" "$out/parent-accepted.receipt.json"
cp "$receipt" "$out/parent-candidate.receipt.json"
sudo -n podman load -i "$archive"
rm -- "$archive" # Only the runner's verified download; remote artifact is retained.
parent=$(jq -er .image_id "$out/archive-verification.json")
cp build/{acceptance-firstboot.sh,acceptance-firstboot.service,stage-acceptance-node.sh,25-quattro-user.sh,acceptance-dependencies.sh} "$work/ctx/build/"
cp scripts/ci/acceptance-overlay.Containerfile "$work/ctx/Containerfile"
# Remove the fixture password before it enters any derived layer. The account
# is console-autologin only and SSH is masked, including on subsequent boots.
python3 - "$work/ctx/build/acceptance-firstboot.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text();old="printf 'omarchy:omarchy\\n' | chpasswd"
assert s.count(old)==1
p.write_text(s.replace(old,'passwd -l omarchy'))
PY
cat >"$work/ctx/build/desktop-proof.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for ((i=0;i<180;i++)); do
    if pgrep -u omarchy -x Hyprland >/dev/null && pgrep -u omarchy -x quickshell >/dev/null; then
        printf 'OMARCHY_BOOTED=' >/dev/ttyS0
        bootc status --format=json | jq -c . >/dev/ttyS0
        printf 'OMARCHY_INTERACTIVE_READY\n' >/dev/ttyS0
        exit 0
    fi
    sleep 2
done
exit 1
SH
cat >"$work/ctx/build/desktop-proof.service" <<'UNIT'
[Unit]
After=display-manager.service
[Service]
Type=oneshot
ExecStart=/usr/libexec/interactive-desktop-proof
[Install]
WantedBy=graphical.target
UNIT
cat >>"$work/ctx/Containerfile" <<'CF'
COPY build/desktop-proof.sh /usr/libexec/interactive-desktop-proof
COPY build/desktop-proof.service /usr/lib/systemd/system/interactive-desktop-proof.service
RUN chmod 0755 /usr/libexec/interactive-desktop-proof && \
    install -m 0644 /usr/lib/omarchy-acceptance/autologin.conf /etc/sddm.conf.d/90-interactive-test.conf && \
    systemctl mask sshd.service sshd.socket && \
    systemctl enable interactive-desktop-proof.service && \
    bootc container lint --fatal-warnings
LABEL org.opencontainers.image.title="Omarchy disposable interactive VM, not a release"
CF
sudo -n podman build --pull=never --format=oci --build-arg "CANDIDATE_IMAGE=$parent" -t localhost/omarchy-interactive:personal -f "$work/ctx/Containerfile" "$work/ctx" >"$out/overlay-build.log" 2>&1
sudo -n podman save --format oci-archive localhost/omarchy-interactive:personal >"$work/interactive.oci.tar"
overlay_digest=$(tar -xOf "$work/interactive.oci.tar" index.json | jq -er '.manifests[0].digest')
truncate -s 40G "$work/disk.raw"
sudo -n podman run --rm --privileged --pid=host --pull=never \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v /etc/containers:/etc/containers \
    -v "$work:/data" localhost/omarchy-interactive:personal \
    bootc install to-disk --source-imgref oci-archive:/data/interactive.oci.tar \
    --composefs-backend --via-loopback --filesystem btrfs --wipe --bootloader systemd /data/disk.raw \
    >"$out/bootc-install.log" 2>&1
qemu-img convert -f raw -O qcow2 "$work/disk.raw" "$work/test.qcow2"
sudo -n rm -- "$work/disk.raw" "$work/interactive.oci.tar"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$work/vars.fd"
[[ -c /dev/kvm ]] && sudo -n test -w /dev/kvm
sudo -n qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 2 -m 4096 \
    -drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd" \
    -drive "if=pflash,format=raw,file=$work/vars.fd" \
    -drive "if=virtio,format=qcow2,file=$work/test.qcow2" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 -vga virtio -display none \
    -serial "file:$out/guest-serial.log" -qmp "unix:$work/qmp.sock,server=on,wait=off" -pidfile "$pidfile" -daemonize
deadline=$((SECONDS+720))
until grep -Fq OMARCHY_INTERACTIVE_READY "$out/guest-serial.log"; do
    ((SECONDS < deadline))
    sudo -n kill -0 "$(cat "$pidfile")"
    sleep 3
done
sed -n 's/^.*OMARCHY_BOOTED=//p' "$out/guest-serial.log" | tail -n1 >"$out/booted-status.json"
jq -e --arg digest "$overlay_digest" '.status.booted.image.imageDigest==$digest' "$out/booted-status.json" >/dev/null
sudo -n python3 scripts/ci/capture-vm-screen.py "$work/qmp.sock" "$out/desktop.png"
sudo -n python3 - "$work/qmp.sock" <<'PY'
import json,socket,sys
with socket.socket(socket.AF_UNIX) as c:
 c.settimeout(15);c.connect(sys.argv[1]);s=c.makefile('rwb');json.loads(s.readline())
 for i,command in enumerate(['qmp_capabilities','system_powerdown']):
  s.write((json.dumps({'execute':command,'id':i})+'\n').encode());s.flush()
  while json.loads(s.readline()).get('id')!=i:pass
PY
deadline=$((SECONDS+120))
while sudo -n kill -0 "$(cat "$pidfile")" 2>/dev/null; do ((SECONDS < deadline)); sleep 2; done
qemu-img check "$work/test.qcow2" >"$out/qcow-check.txt"
qemu-img convert -c -f qcow2 -O qcow2 "$work/test.qcow2" "$out/omarchy-341dbb8-interactive-x86_64.qcow2"
qemu-img check "$out/omarchy-341dbb8-interactive-x86_64.qcow2" >>"$out/qcow-check.txt"
(cd "$out"; sha256sum ./*.qcow2 desktop.png >SHA256SUMS)
jq -n --arg source "$source_sha" --arg parent "$parent_digest" --arg overlay "$overlay_digest" --arg harness "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" \
 '{scope:"UNSIGNED disposable personal VM, not release or installer qualification",source_sha:$source,parent_manifest:$parent,derived_manifest:$overlay,harness_sha:$harness,run_id:$run,boot:"actual KVM/Q35/UEFI Hyprland+Quickshell; clean shutdown; booted digest verified",login:"omarchy console autologin; password locked; SSH masked; passwordless sudo is test-only",disk:"40GiB sparse virtual disk; virtio; standalone qcow2"}' >"$out/vm-receipt.json"
cat >"$out/README.txt" <<'TXT'
DISPOSABLE PERSONAL TEST VM — NOT A SIGNED RELEASE OR INSTALLER ISO

Extract the downloaded Actions artifact ZIP to a folder your user can read.
Run sha256sum -c SHA256SUMS in that folder before import.

In Flatpak virt-manager connected to QEMU/KVM USER session:
Create a new virtual machine -> Import existing disk image -> Browse local ->
omarchy-341dbb8-interactive-x86_64.qcow2. Select Generic Linux/Arch Linux,
4096 MiB RAM, 2 vCPUs, and Customize configuration before install.
Select x86_64, Q35 chipset, UEFI/OVMF firmware without Secure Boot, KVM,
VirtIO disk bus, Virtio video, and SPICE display. Create fresh firmware/NVRAM;
the disk includes the UEFI fallback loader. Initially disconnect the NIC or
use USER-mode networking without forwarded ports. Do not attach host disks.

Console autologin account: omarchy. Its password is LOCKED, not a published
credential. SSH service/socket are masked. This isolated test account has
passwordless sudo for experimentation. No secrets are required or included.
Set a unique password with sudo passwd omarchy if you want password login;
never reuse workstation credentials. Do not use this disk for production.

Provenance: parent source341dbb85351994fad83012e40c5bb894c96d1cb5,
qualified run44768835123, candidate artifact14647899042. See JSON receipts
for the verified parent and distinct test-overlay digests. This download is
a bootable disk, not the OCI candidate tar and not a bootable installer ISO.

Trust: unsigned workflow-derived test fixture; no release signature or ISO
qualification is claimed. Upstream Omarchy at the pinned revision is MIT;
packages retain their own license notices under /usr/share/licenses. This
repository supplies no top-level LICENSE; this is not a blanket redistribution
license or a claim that all bundled software is MIT.
TXT
