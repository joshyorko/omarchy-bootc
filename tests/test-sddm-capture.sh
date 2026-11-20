#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/etc/sddm.conf.d" "$fixture/run" "$fixture/bin" "$fixture/usr/lib/omarchy-acceptance"
printf '[Autologin]\nUser=omarchy\n' >"$fixture/usr/lib/omarchy-acceptance/autologin.conf"
cp "$fixture/usr/lib/omarchy-acceptance/autologin.conf" "$fixture/original"
printf '[Theme]\nCurrent=omarchy\n' >"$fixture/etc/sddm.conf.d/10-theme.conf"
cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -n ]]
shift
exec "$@"
EOF
cat >"$fixture/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'restart sddm' ]]
[[ -f "$SDDM_FIXTURE/captured" ]] || { echo 'SDDM restarted before greeter capture' >&2; exit 1; }
[[ ! -f "$SDDM_FIXTURE/restarted" ]] || { echo 'SDDM restarted more than once' >&2; exit 1; }
touch "$SDDM_FIXTURE/restarted"
EOF
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
export SDDM_FIXTURE="$fixture"
run_guest() {
    # SDDM reads all files in its config directory, including .disabled files.
    if [[ "$1" == pgrep* ]]; then
        if grep -Rq '^User=omarchy$' "$fixture/etc/sddm.conf.d"; then return 1; fi
        return 0
    fi
    local command="$1"
    command="${command//\/etc\/sddm.conf.d/$fixture/etc/sddm.conf.d}"
    command="${command//\/run\//$fixture/run/}"
    command="${command//\/usr\/lib\/omarchy-acceptance/$fixture/usr/lib/omarchy-acceptance}"
    bash -euo pipefail -c "$command"
}
sleep() { :; }
fail() { echo "$*" >&2; exit 1; }
capture_vm_screen() {
    [[ "$1" == sddm-greeter ]]
    if grep -Rq '^User=omarchy$' "$fixture/etc/sddm.conf.d"; then return 1; fi
    touch "$fixture/captured"
}
# Load only the real capture function, without starting the VM harness.
definition="$(sed -n '/^capture_sddm_greeter() {$/,/^}$/p' "$root/scripts/ci/vm-smoke.sh")"
[[ -n "$definition" ]]
eval "$definition"
capture_sddm_greeter
[[ -f "$fixture/captured" && -f "$fixture/restarted" ]]
cmp "$fixture/original" "$fixture/etc/sddm.conf.d/90-omarchy-acceptance.conf"
[[ -f "$fixture/etc/sddm.conf.d/10-theme.conf" ]]
[[ -z "$(ls -A "$fixture/run")" ]]
echo 'PASS: greeter-first boot captures before enabling autologin with one restart'
