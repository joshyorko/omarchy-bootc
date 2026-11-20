#!/usr/bin/env bash
set -euo pipefail

ctx=/ctx/custom/bootc
lib=/usr/lib/omarchy-bootc
on_error() {
    local rc="${1:-1}" line="${2:-unknown}" command="${3:-unknown}"
    printf 'install-bootc-update failed line=%s command=%q status=%s\n' "$line" "$command" "$rc" >&2
    ls -ld /usr/local /usr/local/bin /var/usrlocal /var/usrlocal/bin "$lib" 2>&1 || true
    exit "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
install -d -m 0755 "$lib" /usr/libexec /usr/local/bin /usr/lib/systemd/user /etc/systemd/user/graphical-session.target.wants /etc/profile.d
cat >/etc/profile.d/omarchy-bootc-path.sh <<'EOF'
export PATH=/usr/local/bin:$PATH
EOF
chmod 0644 /etc/profile.d/omarchy-bootc-path.sh

for file in omarchy-bootc-common.sh omarchy-bootc-update omarchy-bootc-update-available; do
    install -m 0755 "$ctx/$file" "$lib/${file/omarchy-bootc-common.sh/update-common.sh}"
done
install -m 0755 "$ctx/omarchy-bootc-finalize" /usr/libexec/omarchy-bootc-finalize
install -m 0755 "$ctx/omarchy-bootc-status" /usr/libexec/omarchy-bootc-status
install -m 0755 "$ctx/omarchy-bootc-clear-transaction" /usr/libexec/omarchy-bootc-clear-transaction
install -m 0755 "$ctx/omarchy-bootc-check" /usr/libexec/omarchy-bootc-check
install -d -m 0750 /etc/sudoers.d
printf '%s\n' \
    '%wheel ALL=(root) NOPASSWD: /usr/libexec/omarchy-bootc-check ""' \
    '%wheel ALL=(root) NOPASSWD: /usr/libexec/omarchy-bootc-status ""' \
    '%wheel ALL=(root) NOPASSWD: /usr/libexec/omarchy-bootc-clear-transaction ""' \
    > /etc/sudoers.d/20-omarchy-update-check
chmod 0440 /etc/sudoers.d/20-omarchy-update-check
visudo -cf /etc/sudoers.d/20-omarchy-update-check
visudo -c
install -m 0644 "$ctx/omarchy-bootc-finalize.service" /usr/lib/systemd/user/omarchy-bootc-finalize.service
install -m 0755 "$ctx/omarchy-wrapper" "$lib/omarchy-wrapper"
install -m 0755 "$ctx/omarchy-update-wrapper" "$lib/omarchy-update-wrapper"
install -m 0755 "$ctx/omarchy-update-available-wrapper" "$lib/omarchy-update-available-wrapper"
ln -sfn "$lib/omarchy-wrapper" /usr/local/bin/omarchy
ln -sfn "$lib/omarchy-update-wrapper" /usr/local/bin/omarchy-update
ln -sfn "$lib/omarchy-update-available-wrapper" /usr/local/bin/omarchy-update-available
ln -sfn /usr/libexec/omarchy-bootc-finalize \
    /usr/local/bin/omarchy-bootc-finalize
# Omarchy's graphical session deliberately prepends /usr/share/omarchy/bin.
# Keep the package-owned /usr/bin implementations intact, but project the
# three public update entry points through the bootc wrappers at that dispatch
# boundary.
for command_name in omarchy omarchy-update omarchy-update-available; do
    dispatch_path="/usr/share/omarchy/bin/${command_name}"
    [[ -L "$dispatch_path" ]]
    [[ "$(readlink "$dispatch_path")" == "/usr/bin/${command_name}" ]]
    ln -sfn "/usr/local/bin/${command_name}" "$dispatch_path"
    [[ "$(readlink "$dispatch_path")" == "/usr/local/bin/${command_name}" ]]
done
if [[ -d /var/usrlocal/bin ]]; then
    rm -f /var/usrlocal/bin/omarchy /var/usrlocal/bin/omarchy-update \
        /var/usrlocal/bin/omarchy-update-available \
        /var/usrlocal/bin/omarchy-bootc-finalize
fi
ln -sfn /usr/lib/systemd/user/omarchy-bootc-finalize.service \
    /etc/systemd/user/graphical-session.target.wants/omarchy-bootc-finalize.service

# Install explicit container signature policy (fail-closed default with explicit
# per-transport rules and sigstore attachments enabled for the published repo).
install -d -m 0755 /etc/containers /etc/containers/registries.d
cat >/etc/containers/policy.json <<'EOF'
{
  "default": [
    {
      "type": "reject"
    }
  ],
  "transports": {
    "docker": {
      "": [
        {
          "type": "insecureAcceptAnything"
        }
      ]
    },
    "docker-daemon": {
      "": [
        {
          "type": "insecureAcceptAnything"
        }
      ]
    },
    "containers-storage": {
      "": [
        {
          "type": "insecureAcceptAnything"
        }
      ]
    },
    "dir": {
      "": [
        {
          "type": "insecureAcceptAnything"
        }
      ]
    },
    "oci": {
      "": [
        {
          "type": "insecureAcceptAnything"
        }
      ]
    },
    "oci-archive": {
      "": [
        {
          "type": "insecureAcceptAnything"
        }
      ]
    },
    "docker-archive": {
      "": [
        {
          "type": "insecureAcceptAnything"
        }
      ]
    },
    "tarball": {
      "": [
        {
          "type": "insecureAcceptAnything"
        }
      ]
    }
  }
}
EOF
chmod 0644 /etc/containers/policy.json
jq -e '.default == [{"type":"reject"}] and .transports.docker[""] == [{"type":"insecureAcceptAnything"}]' \
    /etc/containers/policy.json >/dev/null
cat >/etc/containers/registries.d/omarchy-bootc.yaml <<'EOF'
docker:
  ghcr.io/joshyorko/omarchy-bootc:
    use-sigstore-attachments: true
EOF
chmod 0644 /etc/containers/registries.d/omarchy-bootc.yaml

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
for command_name in omarchy omarchy-update omarchy-update-available; do
    dispatch_path="/usr/share/omarchy/bin/${command_name}"
    test "$(readlink "$dispatch_path")" = "/usr/local/bin/${command_name}"
    test "$(readlink -f "$dispatch_path")" = "$lib/${command_name}-wrapper"
done
