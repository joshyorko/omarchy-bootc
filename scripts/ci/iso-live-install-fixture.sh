#!/usr/bin/env bash
# Invoked only inside the disposable ISO live session via its actual GNOME UI.
set -euo pipefail
[[ $(id -un) == liveuser && -e /run/initramfs/live && -n ${WAYLAND_DISPLAY:-} ]]
base=http://10.0.2.2:18763
fixture=$(mktemp -d /tmp/omarchy-installer-fixture.XXXXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
curl -fsS "$base/install.ks" -o "$fixture/install.ks"
# Live media does not automatically start Anaconda for inst.ks. The liveinst
# wrapper explicitly rejects that boot option. This automated fixture instead
# selects Anaconda's CLI kickstart mode via its documented LIVECMD override,
# retaining liveinst's device/Wayland/privilege setup. It is NOT interactive UI
# account/disk-selection coverage and changes neither the ISO nor its payload.
sudo -n env \
    DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
    PKEXEC_UID="$(id -u)" FIXTURE_KS="$fixture/install.ks" bash -s <<'ROOT'
set -euo pipefail
exec >/dev/ttyS0 2>&1
finish() {
    local status=$?
    trap - EXIT
    printf 'OMARCHY_INSTALLER_EXIT=%s\n' "$status"
    for log in /tmp/anaconda.log /tmp/program.log /tmp/storage.log /tmp/packaging.log; do
        if [[ -f $log ]]; then printf '\nGuest log: %s\n' "$log"; cat "$log"; fi
    done
    journalctl -b --no-pager -n 150
    exit "$status"
}
trap finish EXIT
printf 'OMARCHY_INSTALLER_LAUNCH_REQUESTED\n'
rpm -qa 'anaconda*'
cat /proc/cmdline
# Announce only an actual backend-ready flag; this is not a completion claim.
(
    for ((attempt=0; attempt<120; attempt++)); do
        if [[ -e /run/anaconda/backend_ready ]]; then
            printf 'OMARCHY_INSTALLER_BACKEND_READY\n'
            exit 0
        fi
        sleep 5
    done
) &
export LIVECMD="anaconda --liveinst --graphical --kickstart=$FIXTURE_KS"
/usr/bin/liveinst
ROOT
