#!/usr/bin/env bash
set -euo pipefail

ctx=/ctx/custom/bootc
lib=/usr/lib/omarchy-bootc
install -d -m 0755 "$lib" /usr/libexec /var/usrlocal/bin /usr/lib/systemd/user /etc/systemd/user/graphical-session.target.wants

for file in omarchy-bootc-common.sh omarchy-bootc-update omarchy-bootc-update-available; do
    install -m 0755 "$ctx/$file" "$lib/${file/omarchy-bootc-common.sh/update-common.sh}"
done
install -m 0755 "$ctx/omarchy-bootc-finalize" /usr/libexec/omarchy-bootc-finalize
install -m 0644 "$ctx/omarchy-bootc-finalize.service" /usr/lib/systemd/user/omarchy-bootc-finalize.service
install -m 0755 "$ctx/omarchy-wrapper" "$lib/omarchy-wrapper"
install -m 0755 "$ctx/omarchy-update-wrapper" "$lib/omarchy-update-wrapper"
install -m 0755 "$ctx/omarchy-update-available-wrapper" "$lib/omarchy-update-available-wrapper"

ln -sfn "$lib/omarchy-wrapper" /usr/local/bin/omarchy
ln -sfn "$lib/omarchy-update-wrapper" /usr/local/bin/omarchy-update
ln -sfn "$lib/omarchy-update-available-wrapper" /usr/local/bin/omarchy-update-available
ln -sfn /usr/libexec/omarchy-bootc-finalize \
    /usr/local/bin/omarchy-bootc-finalize
ln -sfn /usr/lib/systemd/user/omarchy-bootc-finalize.service \
    /etc/systemd/user/graphical-session.target.wants/omarchy-bootc-finalize.service
