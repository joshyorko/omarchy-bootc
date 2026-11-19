#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true || ${OMARCHY_REMOTE_BUILDER:-} == harvester ]] || {
    echo 'Refusing to install runner tools on the workstation' >&2; exit 2;
}
# shellcheck disable=SC1091
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]]
sudo -n sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.edge.kernel.org/ubuntu|g; s|http://security.ubuntu.com/ubuntu|https://mirrors.edge.kernel.org/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources
opts=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o DPkg::Lock::Timeout=120)
sudo -n apt-get "${opts[@]}" -o APT::Update::Error-Mode=any update
sudo -n apt-get "${opts[@]}" install -y --no-install-recommends podman buildah skopeo jq git sudo python3 shellcheck time btrfs-progs ovmf qemu-system-x86 qemu-utils sshpass openssh-client
podman version
qemu-system-x86_64 --version
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then echo 'KVM device accessible'; else echo 'KVM unavailable; software emulation will be recorded'; fi
