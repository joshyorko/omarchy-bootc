#!/usr/bin/env bash
# Invoked only inside the disposable ISO live session via its actual GNOME UI.
set -euo pipefail
[[ $(id -un) == liveuser && -e /run/initramfs/live && -n ${WAYLAND_DISPLAY:-} ]]
base=http://10.0.2.2:18763
fixture=$(mktemp -d /tmp/omarchy-installer-fixture.XXXXXXXX)
exec 3>&1
exec >"$fixture/launcher.log" 2>&1
report() {
    tail -c 262144 "$fixture/launcher.log" |
        curl -sS --connect-timeout 2 --max-time 5 --data-binary @- "$base/launcher-log" >/dev/null 2>&1 || true
}
reporter=''
finish() {
    local status=$?
    trap - EXIT
    printf 'OMARCHY_LIVE_LAUNCHER_EXIT=%s\n' "$status"
    if [[ -n $reporter ]]; then kill "$reporter" 2>/dev/null || true; wait "$reporter" 2>/dev/null || true; fi
    report
    cat "$fixture/launcher.log" >&3
    rm -rf -- "$fixture"
    exit "$status"
}
trap finish EXIT
id
printf 'liveinst=%s\n' "$(command -v liveinst)"
printf 'session=%s runtime=%s display=%s\n' "${XDG_SESSION_TYPE:-}" "$XDG_RUNTIME_DIR" "$WAYLAND_DISPLAY"
rpm -qa 'anaconda*' 'livesys*'
# Capture the actual live-media launch/branding and authorization files, rather
# than infer them from a newer upstream checkout or the installed payload.
shopt -s nullglob
for file in /etc/os-release /usr/share/applications/liveinst.desktop \
    /usr/share/anaconda/gnome/fedora-welcome /etc/xdg/autostart/*welcome* \
    /usr/share/polkit-1/actions/*liveinst* /etc/polkit-1/rules.d/*liveinst*; do
    if [[ -r $file ]]; then printf '\nGuest file: %s\n' "$file"; head -n 120 "$file"; fi
done
# Record privilege diagnostics without depending on arbitrary passwordless sudo.
if command -v sudo >/dev/null; then sudo -n -l || true; fi
report
(while true; do report; sleep 5; done) &
reporter=$!
curl -fsS "$base/install.ks" -o "$fixture/install.ks"
# Use the ISO's actual desktop/polkit entry point. Do not replace authorization
# policy or inject an arbitrary root shell/LIVECMD override. liveinst displays
# its kickstart warning; the host captures and acknowledges that exact dialog.
# This remains an automated CLI fixture, NOT interactive account/disk coverage.
liveinst --kickstart="$fixture/install.ks"
