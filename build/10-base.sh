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

BOOTC_REPO="${BOOTC_REPO:-https://github.com/bootc-dev/bootc.git}"
BOOTC_REF="${BOOTC_REF:-v1.13.0}"

echo "::group:: Install base packages"

# Read package list — strip comments and blank lines
mapfile -t BASE_PKGS < <(grep -v '^#' /ctx/custom/packages/base.packages | grep -v '^$')

if [[ ${#BASE_PKGS[@]} -gt 0 ]]; then
    pacman -S --noconfirm --needed "${BASE_PKGS[@]}"
fi

echo "::endgroup::"

echo "::group:: Build bootc from source"

pacman -S --noconfirm --needed make git rust go-md2man

TMP_BOOTC=$(mktemp -d /tmp/bootc.XXXXXX)
git clone --filter=blob:none --branch "${BOOTC_REF}" --depth 1 "${BOOTC_REPO}" "${TMP_BOOTC}"
make -C "${TMP_BOOTC}" bin install-all

cat > /usr/lib/dracut/dracut.conf.d/30-omarchy-bootc-module.conf <<'EOT'
systemdsystemconfdir=/etc/systemd/system
systemdsystemunitdir=/usr/lib/systemd/system
EOT

cat > /usr/lib/dracut/dracut.conf.d/30-omarchy-bootc.conf <<'EOT'
reproducible=yes
hostonly=no
compress=zstd
add_dracutmodules+=" ostree bootc "
EOT

latest_kver="$(
    find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | sort -V \
        | tail -n 1
)"
dracut --force "/usr/lib/modules/${latest_kver}/initramfs.img"

pacman -Rns --noconfirm make git rust go-md2man || true
pacman -S --clean --noconfirm

rm -rf "${TMP_BOOTC}"

echo "::endgroup::"

echo "::group:: Prepare bootc sysroot"

sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd"

cleanup_paths=(
    /boot
    /home
    /root
    /usr/local
    /srv
    /opt
    /mnt
    /var
    /usr/lib/sysimage/log
)
for path in "${cleanup_paths[@]}"; do
    rm -rf -- "${path}"
done
mkdir -p /sysroot /boot /usr/lib/ostree /var /var/lib
ln -sT sysroot/ostree /ostree
ln -sT var/roothome /root
ln -sT var/srv /srv
ln -sT var/opt /opt
ln -sT var/mnt /mnt
ln -sT var/home /home
ln -sT ../var/usrlocal /usr/local

cat > /usr/lib/tmpfiles.d/bootc-base-dirs.conf <<'EOT'
d /var/opt 0755 root root -
d /var/home 0755 root root -
d /var/mnt 0755 root root -
d /var/srv 0755 root root -
d /var/usrlocal 0755 root root -
d /var/roothome 0700 root root -
d /run/media 0755 root root -
EOT

cat > /usr/lib/ostree/prepare-root.conf <<'EOT'
[composefs]
enabled = yes
[sysroot]
readonly = true
EOT

echo "::endgroup::"

echo "::group:: Create default POC user"

# Explicit VM login user for POC smoke tests.
# Credentials are intentionally simple for local VM bring-up only.
# Username: omarchy
# Password: omarchy
# Note: avoid optional groups that may not exist in minimal images (e.g. podman).
if ! id -u omarchy >/dev/null 2>&1; then
    useradd -m -G wheel,video,audio,input,network -s /bin/bash omarchy
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
