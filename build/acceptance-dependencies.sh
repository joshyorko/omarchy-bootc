#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'acceptance dependencies: %s\n' "$*" >&2
    exit 1
}

require_executable() {
    [[ -f "$1" && -x "$1" ]] || fail "missing executable: $1"
}

require_immutable_command() {
    local path resolved
    path="$(command -v "$1")" || fail "missing command: $1"
    require_executable "$path"
    resolved="$(readlink -f "$path")" || fail "cannot resolve command: $1"
    [[ "$resolved" == /usr/* ]] || fail "command is not image-owned: $1 ($resolved)"
}

require_bootc_options() {
    local help option
    help="$(bootc "$1" ${2:+"$2"} --help)" || fail "unsupported bootc command: $1 $2"
    shift 2
    for option in "$@"; do
        grep -Eq -- "(^|[[:space:],])${option}([=[:space:]]|$)" <<<"$help" \
            || fail "unsupported bootc option: $option"
    done
}

# Keep upstream command-scoped passwordless helpers intact. This guard rejects
# literal unrestricted grants; visudo remains the authority for sudoers syntax.
require_bounded_sudo_policy() {
    awk '
        sub(/\\$/, "") { continued = continued $0; next }
        {
            line = continued $0
            continued = ""
            sub(/#.*/, "", line)
            if (line ~ /NOPASSWD[[:space:]]*:([^#]*,)?[[:space:]]*ALL([[:space:],]|$)/)
                exit 1
        }
    ' "$@" || fail 'unrestricted passwordless sudo policy in product image'
}

require_kernel_headers() {
    local declaration="${1:-/usr/share/omarchy-bootc/kernel-package}"
    local modules_dir="${2:-/usr/lib/modules}"
    local package kernel_version headers_version module_dir release headers_release
    local matches=0
    [[ -s "$declaration" ]] || fail 'missing kernel package declaration'
    package="$(cat "$declaration")"
    [[ "$package" =~ ^[a-zA-Z0-9][a-zA-Z0-9@._+-]*$ ]] || fail 'invalid kernel package declaration'
    kernel_version="$(pacman -Q "$package")" || fail "missing declared kernel: $package"
    headers_version="$(pacman -Q "${package}-headers")" || fail "missing kernel headers: ${package}-headers"
    [[ "${kernel_version#* }" == "${headers_version#* }" ]] \
        || fail "kernel/header package version mismatch: $kernel_version; $headers_version"
    for module_dir in "$modules_dir"/*; do
        [[ -f "$module_dir/pkgbase" ]] || continue
        [[ "$(cat "$module_dir/pkgbase")" == "$package" ]] || continue
        matches=$((matches + 1))
        release="${module_dir##*/}"
        [[ -s "$module_dir/vmlinuz" ]] || fail "missing declared kernel image: $release"
        [[ "$(pacman -Qqo "$module_dir/pkgbase")" == "$package" &&
           "$(pacman -Qqo "$module_dir/vmlinuz")" == "$package" ]] \
            || fail "kernel payload is not owned by $package"
        headers_release="$(readlink -f "$module_dir/build/include/config/kernel.release")" \
            || fail "missing kernel headers release: $release"
        [[ -s "$headers_release" && "$(cat "$headers_release")" == "$release" ]] \
            || fail "kernel/header release mismatch: $release"
        [[ "$(pacman -Qqo "$headers_release")" == "${package}-headers" ]] \
            || fail "kernel headers are not owned by ${package}-headers"
    done
    [[ "$matches" == 1 ]] || fail "expected one installed module tree for $package, found $matches"
}

require_desktop_services() {
    local root="${1:-}" unit state
    for unit in \
        cups.service avahi-daemon.service linux-modules-cleanup.service \
        docker.socket systemd-resolved.service NetworkManager.service \
        power-profiles-daemon.service sddm.service systemd-oomd.service \
        ufw.service sshd.service; do
        [[ -s "$root/usr/lib/systemd/system/$unit" ]] \
            || fail "missing required service unit: $unit"
        state="$(systemctl --root="${root:-/}" is-enabled "$unit")" || fail "required service is not enabled: $unit"
        [[ "$state" == enabled ]] || fail "required service is not enabled: $unit ($state)"
    done
    grep -Fxq ENABLED=yes "$root/etc/ufw/ufw.conf" || fail 'UFW configuration is not enabled'
    [[ -s "$root/usr/lib/systemd/user/pipewire-pulse.service" ]] || fail 'missing pipewire-pulse user service'
    [[ "$(pacman -Qqo "$root/usr/lib/systemd/user/pipewire-pulse.service")" == pipewire-pulse ]] \
        || fail 'pipewire-pulse user service is not package-owned'
}

main() {
    local phase="${1:-}" command_name path user_home graphical_path graphical_command
    local update_output availability_output update_status availability_status
    [[ $# == 1 && "$phase" =~ ^(final|overlay|guest)$ ]] || {
        printf 'Usage: %s <final|overlay|guest>\n' "$0" >&2
        return 2
    }
    # Do not let user-local programs satisfy an image dependency. User-local
    # Node is intentionally a separate post-provision check below.
    export PATH=/usr/local/bin:/usr/bin:/usr/share/omarchy/bin

    # Product update + firstboot + guest-native + remote vm-smoke commands.
    # Host QEMU/podman/SSH transport dependencies belong to the VM harness.
    for command_name in \
        bash sh env sudo visudo bootc skopeo jq flock getent install dirname id cut \
        mktemp rm cat sed readlink grep stat sha256sum \
        groupadd useradd chpasswd runuser chown chmod cp touch \
        git pacman pacman-conf journalctl systemctl systemd-cat busctl \
        timeout logger pgrep find sort head tail awk xargs cmp mkdir mv date \
        tee rg sleep tar gzip ls uname curl inotifywait basename mise \
        Hyprland hyprctl quickshell qs \
        grim tesseract setsid foot chromium xdg-terminal-exec nvim omawrite \
        lpstat lpinfo upower wtype wl-copy wl-paste findmnt docker fastfetch \
        tmux xdg-mime xdg-user-dir wpctl xdg-settings fc-match perl ln \
        md5sum base64 nproc vipsthumbnail pkill setpriv ip nmcli tr pactl \
        omarchy-toggle omarchy-menu-images omarchy-clipboard-paste-text \
        omarchy-menu-emoji-insert \
        omarchy-menu omarchy-weather-location omarchy-toggle-bar omarchy-version \
        omarchy-pkg-present omarchy-default-browser omarchy-default-terminal \
        omarchy-default-editor omarchy-theme-current omarchy-theme-bg-current \
        omarchy-font-current omarchy-theme-bg-switcher omarchy-theme-switcher \
        omarchy-bar omarchy-network-status omarchy-network-band omarchy-dns \
        omarchy-audio-sink-availability omarchy-audio-output-sink omarchy-audio-tuning \
        omarchy-monitor-state omarchy-brightness-display omarchy-hyprland-monitor-scaling \
        omarchy omarchy-shell omarchy-provision-user omarchy-migrate omarchy-hook \
        omarchy-plugin-list omarchy-plugin-validate omarchy-plugin-add \
        omarchy-plugin-catalog omarchy-plugin-enable omarchy-plugin-disable \
        omarchy-plugin-remove omarchy-plugin-clone omarchy-git-url-check \
        omarchy-restart-shell omarchy-hyprland-session-locked omarchy-launch-shell \
        omarchy-notification-send omarchy-default-agent omarchy-agent \
        omarchy-agent-prompt omarchy-cmd-missing; do
        require_immutable_command "$command_name"
    done

    for path in \
        /usr/bin/true /usr/bin/test \
        /usr/lib/omarchy-bootc/update-common.sh \
        /usr/lib/omarchy-bootc/omarchy-bootc-update \
        /usr/lib/omarchy-bootc/omarchy-bootc-update-available \
        /usr/lib/omarchy-bootc/omarchy-wrapper \
        /usr/lib/omarchy-bootc/omarchy-update-wrapper \
        /usr/lib/omarchy-bootc/omarchy-update-available-wrapper \
        /usr/libexec/omarchy-bootc-finalize \
        /usr/bin/omarchy /usr/bin/omarchy-menu /usr/bin/omarchy-theme-list; do
        require_executable "$path"
    done
    [[ -d /usr/local && ! -L /usr/local ]] || fail '/usr/local must be immutable image content'
    for path in omarchy omarchy-update omarchy-update-available; do
        [[ "$(readlink -f "/usr/local/bin/$path")" == "/usr/lib/omarchy-bootc/${path}-wrapper" ]] \
            || fail "wrong update dispatch: $path"
    done
    [[ "$(readlink -f /usr/local/bin/omarchy-bootc-finalize)" == /usr/libexec/omarchy-bootc-finalize ]] \
        || fail 'wrong update finalizer dispatch'

    # Hyprland intentionally prepends the upstream dispatch directory. Verify
    # all three public entry points still reach the image-owned bootc shims.
    graphical_path=/usr/share/omarchy/bin:/usr/local/bin:/usr/bin
    for path in omarchy omarchy-update omarchy-update-available; do
        graphical_command="$(PATH="$graphical_path" command -v "$path")"
        [[ "$graphical_command" == "/usr/share/omarchy/bin/$path" ]] \
            || fail "graphical PATH bypasses bootc dispatch: $path ($graphical_command)"
        [[ "$(readlink -f "$graphical_command")" == \
            "/usr/lib/omarchy-bootc/${path}-wrapper" ]] \
            || fail "graphical dispatch does not reach bootc: $path"
    done
    graphical_command="$(PATH="$graphical_path" command -v omarchy)"

    update_status=0
    update_output="$(PATH="$graphical_path" "$graphical_command" update --unsupported 2>&1)" \
        || update_status=$?
    [[ "$update_status" == 2 ]] \
        || fail "graphical omarchy update accepted an unsupported option (status $update_status)"
    grep -Fq 'omarchy update: unsupported option --unsupported' <<<"$update_output" \
        || fail 'graphical omarchy update did not execute the bootc wrapper'

    update_output="$(PATH="$graphical_path" "$graphical_command" update --help 2>&1)" ||
        fail 'graphical omarchy update --help failed'
    grep -Fq 'Usage: omarchy update [-y]' <<<"$update_output" ||
        fail 'graphical omarchy update did not expose the bootc wrapper help'

    availability_status=0
    availability_output="$(PATH="$graphical_path" omarchy-update-available 2>&1)" \
        || availability_status=$?
    [[ "$availability_status" == 0 || "$availability_status" == 1 ]] \
        || fail "graphical availability command failed before its bootc contract (status $availability_status)"
    grep -Eq '^(Omarchy update check failed|Cannot determine bootc update availability:|bootc image update available |Omarchy image is up to date$)' \
        <<<"$availability_output" \
        || fail 'graphical availability command did not execute the bootc helper'
    if grep -Fxq 'Omarchy is up to date' <<<"$availability_output"; then
        fail 'graphical availability command reached the pacman implementation'
    fi
    availability_status=0
    availability_output="$(PATH="$graphical_path" omarchy-update-available unexpected 2>&1)" \
        || availability_status=$?
    [[ "$availability_status" == 2 ]] \
        || fail "graphical availability helper accepted an argument (status $availability_status)"
    grep -Fq 'Image availability accepts no arguments' <<<"$availability_output" \
        || fail 'graphical availability helper did not enforce its argument boundary'

    for path in \
        /usr/share/omarchy/bin/omarchy-shell-config \
        /usr/share/tessdata/eng.traineddata \
        /usr/share/omarchy/shell/shell.qml \
        /usr/share/omarchy/shell/plugins/panels/clock/manifest.json \
        /usr/share/omarchy/default/agents/skills/omarchy/SKILL.md \
        /usr/share/omarchy/default/agents/skills/diagnose-crash/SKILL.md \
        /usr/share/sddm/themes/omarchy/Main.qml \
        /usr/share/omarchy/default/wayland-sessions/omarchy.desktop \
        /usr/share/wayland-sessions/omarchy.desktop \
        /usr/lib/systemd/user/omarchy-bootc-finalize.service \
        /usr/lib/systemd/system/sshd.service \
        /usr/lib/systemd/system/sddm.service \
        /etc/skel/.config/hypr/hyprland.lua \
        /etc/skel/.config/omarchy/shell.json; do
        [[ -s "$path" && -r "$path" ]] || fail "missing image file: $path"
    done
    for path in /usr/share/omarchy/shell/plugins /usr/share/omarchy/themes; do
        [[ -d "$path" ]] || fail "missing image directory: $path"
    done
    cmp -s /usr/share/omarchy/default/wayland-sessions/omarchy.desktop \
        /usr/share/wayland-sessions/omarchy.desktop || fail 'session projection differs from upstream'
    require_kernel_headers /usr/share/omarchy-bootc/kernel-package /usr/lib/modules
    require_desktop_services /
    perl -MEncode -MJSON::PP -e 1 || fail 'clipboard Perl modules missing'

    # These help probes execute the actual pinned binary without staging an
    # image, accessing a registry, or requiring a booted deployment.
    bootc --version
    sudo --version >/dev/null
    require_bootc_options status '' --format
    require_bootc_options upgrade '' --check
    require_bootc_options switch '' --transport
    require_bootc_options rollback ''
    require_bootc_options install to-disk --source-imgref --target-imgref \
        --target-transport --composefs-backend --via-loopback --filesystem --wipe --bootloader
    getent group wheel >/dev/null || fail 'wheel group is missing'

    if [[ "$phase" == guest ]]; then
        [[ "$(id -un)" == omarchy ]] || fail 'guest phase must run as the provisioned omarchy user'
        sudo -n true || fail 'acceptance passwordless elevation is unavailable'
        sudo -n visudo -c || fail 'invalid guest sudoers policy'
    else
        (( EUID == 0 )) || fail "$phase phase must run as image root"
        visudo -cf /etc/sudoers.d/10-omarchy-wheel
        visudo -c
        grep -Fxq '%wheel ALL=(ALL:ALL) PASSWD: ALL' /etc/sudoers.d/10-omarchy-wheel \
            || fail 'product wheel policy must require a password'
    fi

    if [[ "$phase" == final ]]; then
        ! getent passwd omarchy >/dev/null || fail 'acceptance account leaked into final'
        [[ ! -e /etc/sudoers.d/90-omarchy-acceptance ]] || fail 'acceptance sudo policy leaked into final'
        require_bounded_sudo_policy /etc/sudoers /etc/sudoers.d/*
    else
        require_executable /usr/libexec/omarchy-acceptance-firstboot
        [[ -s /usr/lib/systemd/system/omarchy-acceptance-firstboot.service ]] \
            || fail 'acceptance firstboot unit missing'
        [[ -s /usr/lib/omarchy-acceptance/packages/SHASUMS256.txt ]] \
            || fail 'staged Node checksum missing'
        (cd /usr/lib/omarchy-acceptance/packages && sha256sum -c SHASUMS256.txt) \
            || fail 'staged Node archive is missing or corrupt'
    fi

    if [[ "$phase" == guest ]]; then
        user_home="$(getent passwd omarchy | cut -d: -f6)"
        [[ "$(readlink -f "$HOME")" == "$(readlink -f "$user_home")" ]] || fail 'guest HOME differs from account home'
        [[ -f /var/lib/omarchy-acceptance/ready ]] || fail 'firstboot is not ready'
        [[ -f "$HOME/.local/state/omarchy/done/finalize-user" ]] || fail 'user finalization is incomplete'
        [[ -s "$HOME/.config/hypr/hyprland.lua" && -s "$HOME/.config/omarchy/shell.json" ]] \
            || fail 'user session configuration missing'
        [[ -s "$HOME/.local/state/omarchy/current/theme.name" ]] || fail 'user theme missing'
        for path in .agents/skills .claude/skills .codex/skills .pi/agent/skills .hermes/skills; do
            [[ "$(readlink -f "$HOME/$path/omarchy")" == /usr/share/omarchy/default/agents/skills/omarchy ]] \
                || fail "official user skill missing: $path/omarchy"
        done
        require_executable "$HOME/.local/share/mise/shims/node"
        "$HOME/.local/share/mise/shims/node" --version
        # Live compositor/IPC, reboot persistence and deployment identity remain
        # the runtime acceptance gates, not claims made by this preflight.
    fi
    printf 'acceptance dependencies passed: %s\n' "$phase"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
