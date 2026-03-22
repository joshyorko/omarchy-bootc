#!/usr/bin/bash
# shellcheck shell=bash
#
# 10-base.sh — Install core system packages for omarchy-bootc
#
# Runs at OCI build time via:
#   RUN --mount=type=bind,from=ctx ... /ctx/build/10-base.sh
#
# Package manager: pacman (not dnf5, rpm-ostree, or Fedora tooling)

set -eoux pipefail

echo "::group:: Install base packages"

# Read package list — strip comments and blank lines
mapfile -t BASE_PKGS < <(grep -v '^#' /ctx/custom/packages/base.packages | grep -v '^$')

if [[ ${#BASE_PKGS[@]} -gt 0 ]]; then
    pacman -S --noconfirm --needed "${BASE_PKGS[@]}"
fi

echo "::endgroup::"

echo "::group:: Create default POC user"

# Explicit VM login user for POC smoke tests.
# Credentials are intentionally simple for local VM bring-up only.
# Username: omarchy
# Password: omarchy
if ! id -u omarchy >/dev/null 2>&1; then
    useradd -m -G wheel,video,audio,input,network,podman -s /bin/bash omarchy
    echo 'omarchy:omarchy' | chpasswd
fi

mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/10-omarchy-wheel <<'EOT'
%wheel ALL=(ALL:ALL) ALL
EOT
chmod 0440 /etc/sudoers.d/10-omarchy-wheel

echo "::endgroup::"

echo "::group:: Install systemd units"

# Copy project-supplied systemd units into the image
if [[ -d /ctx/systemd/system ]]; then
    mkdir -p /usr/lib/systemd/system
    find /ctx/systemd/system -maxdepth 1 -type f -name '*.service' \
        -exec cp -v {} /usr/lib/systemd/system/ \;
fi

echo "::endgroup::"

echo "::group:: Stage first-boot helper"

if [[ -d /ctx/custom/first-boot ]]; then
    mkdir -p /usr/lib/omarchy
    cp -r /ctx/custom/first-boot/. /usr/lib/omarchy/
    chmod +x /usr/lib/omarchy/*.sh 2>/dev/null || true
fi

echo "::endgroup::"

echo "Base build complete."
