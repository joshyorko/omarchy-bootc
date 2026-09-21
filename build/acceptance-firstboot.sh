#!/usr/bin/env bash
set -euo pipefail

acceptance_state=/var/lib/omarchy-acceptance
ready_marker="${acceptance_state}/ready"
[[ ! -f "${ready_marker}" ]] || exit 0

install -d -m 0755 "${acceptance_state}"

if ! getent group wheel >/dev/null; then
    groupadd wheel
fi
if ! id omarchy >/dev/null 2>&1; then
    useradd --create-home --groups wheel --shell /bin/bash omarchy
fi

printf 'omarchy:omarchy\n' | chpasswd
cat >/etc/sudoers.d/90-omarchy-acceptance <<'EOF'
omarchy ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/90-omarchy-acceptance

install -d -m 0755 /var/lib/omarchy/provisioning/packages
cp -a /usr/lib/omarchy-acceptance/packages/. /var/lib/omarchy/provisioning/packages/

user_home="$(getent passwd omarchy | cut -d: -f6)"
[[ -f "${user_home}/.config/hypr/hyprland.lua" ]]
[[ -f "${user_home}/.config/omarchy/shell.json" ]]
chown -R omarchy:omarchy "${user_home}"

runuser -u omarchy -- env \
    HOME="${user_home}" \
    USER=omarchy \
    LOGNAME=omarchy \
    OMARCHY_SETUP_CONTEXT=provision-owner \
    OMARCHY_USER_NAME='Omarchy Acceptance' \
    OMARCHY_USER_EMAIL='acceptance@omarchy.invalid' \
    PATH=/usr/share/omarchy/bin:/usr/local/sbin:/usr/local/bin:/usr/bin \
    /usr/bin/omarchy-provision-user --first-install

marker="${user_home}/.local/state/omarchy/done/finalize-user"
[[ -f "${marker}" ]]
[[ -s "${user_home}/.local/state/omarchy/current/theme.name" ]]
[[ -L "${user_home}/.agents/skills/omarchy" ]]
[[ "$(readlink "${user_home}/.agents/skills/omarchy")" == "/usr/share/omarchy/default/agents/skills/omarchy" ]]
grep -Fq "file://${user_home}/Downloads Downloads" "${user_home}/.config/gtk-3.0/bookmarks"
compgen -G "${user_home}/.local/state/omarchy/migrations/*.sh" >/dev/null

second_run="$(runuser -u omarchy -- env HOME="${user_home}" USER=omarchy LOGNAME=omarchy PATH=/usr/share/omarchy/bin:/usr/bin /usr/bin/omarchy-provision-user)"
grep -Fq 'User finalization already complete' <<<"${second_run}"

touch "${ready_marker}"
