#!/usr/bin/env bash
set -euo pipefail

install -Dm755 \
    /ctx/build/acceptance-firstboot.sh \
    /usr/libexec/omarchy-acceptance-firstboot
install -Dm644 \
    /ctx/build/acceptance-firstboot.service \
    /usr/lib/systemd/system/omarchy-acceptance-firstboot.service
systemctl enable omarchy-acceptance-firstboot.service
systemctl mask omarchy-adopt-existing-user.service
rm -f /etc/systemd/system/display-manager.service.d/10-omarchy-adoption.conf
