#!/usr/bin/env bash
set -euo pipefail

ctx=/ctx/custom/bootc
lib=/usr/lib/omarchy-bootc
trap 'rc=$?; printf "install-bootc-update failed line=%s command=%q status=%s\n" "$LINENO" "$BASH_COMMAND" "$rc" >&2; ls -ld /usr/local /usr/local/bin /var/usrlocal /var/usrlocal/bin "$lib" 2>&1 || true; exit "$rc"' ERR
install -d -m 0755 "$lib" /usr/libexec /usr/local/bin /usr/lib/systemd/user /etc/systemd/user/graphical-session.target.wants /etc/profile.d
printf '%s\n' 'export PATH=/usr/local/bin:$PATH' > /etc/profile.d/omarchy-bootc-path.sh
chmod 0644 /etc/profile.d/omarchy-bootc-path.sh

for file in omarchy-bootc-common.sh omarchy-bootc-update omarchy-bootc-update-available; do
    install -m 0755 "$ctx/$file" "$lib/${file/omarchy-bootc-common.sh/update-common.sh}"
done
install -m 0755 "$ctx/omarchy-bootc-finalize" /usr/libexec/omarchy-bootc-finalize
install -m 0644 "$ctx/omarchy-bootc-finalize.service" /usr/lib/systemd/user/omarchy-bootc-finalize.service
install -m 0755 "$ctx/omarchy-wrapper" "$lib/omarchy-wrapper"
install -m 0755 "$ctx/omarchy-update-wrapper" "$lib/omarchy-update-wrapper"
install -m 0755 "$ctx/omarchy-update-available-wrapper" "$lib/omarchy-update-available-wrapper"

install -m 0755 "$lib/omarchy-wrapper" /usr/local/bin/omarchy
ln -sfn "$lib/omarchy-update-wrapper" /usr/local/bin/omarchy-update
ln -sfn "$lib/omarchy-update-available-wrapper" /usr/local/bin/omarchy-update-available
ln -sfn /usr/libexec/omarchy-bootc-finalize \
    /usr/local/bin/omarchy-bootc-finalize
if [[ -d /var/usrlocal/bin ]]; then
    rm -f /var/usrlocal/bin/omarchy /var/usrlocal/bin/omarchy-update \
        /var/usrlocal/bin/omarchy-update-available \
        /var/usrlocal/bin/omarchy-bootc-finalize
fi
ln -sfn /usr/lib/systemd/user/omarchy-bootc-finalize.service \
    /etc/systemd/user/graphical-session.target.wants/omarchy-bootc-finalize.service

test -d /usr/local && ! test -L /usr/local
test -x /usr/local/bin/omarchy
resolved_omarchy="$(PATH=/usr/local/bin:/usr/bin:/bin command -v omarchy)"
test "$resolved_omarchy" = /usr/local/bin/omarchy
test "$(readlink -f /usr/local/bin/omarchy)" = "$lib/omarchy-wrapper"
test "$(readlink -f /usr/local/bin/omarchy-update)" = "$lib/omarchy-update-wrapper"
test "$(readlink -f /usr/local/bin/omarchy-bootc-finalize)" = /usr/libexec/omarchy-bootc-finalize
for stale in omarchy omarchy-update omarchy-update-available omarchy-bootc-finalize; do
    test ! -e "/var/usrlocal/bin/$stale"
done
