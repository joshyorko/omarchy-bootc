#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
install_script="${root_dir}/build/install-bootc-update.sh"
wrapper="${root_dir}/custom/bootc/omarchy-wrapper"
assembly="${root_dir}/build/20-quattro.sh"

# These assertions preserve literal source syntax.
# shellcheck disable=SC2016
grep -Fq 'ln -sfn "$lib/omarchy-wrapper" /usr/local/bin/omarchy' "${install_script}"
grep -Fq 'PATH=/usr/local/bin:/usr/bin:/bin command -v omarchy' "${install_script}"
# This assertion preserves literal source syntax.
# shellcheck disable=SC2016
grep -Fq 'export PATH=/usr/local/bin:$PATH' "${install_script}"
# This assertion preserves literal source syntax.
# shellcheck disable=SC2016
grep -Fq 'var/usrlocal/bin/$stale' "${install_script}"
grep -Fq 'update|up)' "${wrapper}"
grep -Fq 'exec /usr/lib/omarchy-bootc/omarchy-bootc-update' "${wrapper}"
grep -Fq 'exec /usr/bin/omarchy' "${wrapper}"
grep -Fq 'EUID == 0 && $# == 0' "${root_dir}/custom/bootc/omarchy-bootc-check"
grep -Fq '/usr/bin/env -i' "${root_dir}/custom/bootc/omarchy-bootc-check"
grep -Fq 'PATH=/usr/bin:/usr/local/bin HOME=/root USER=root LOGNAME=root' \
    "${root_dir}/custom/bootc/omarchy-bootc-check"
grep -Fq 'source /usr/lib/omarchy-bootc/update-common.sh' \
    "${root_dir}/custom/bootc/omarchy-bootc-update"
grep -Fq 'OMARCHY_BOOTC_BIN=/usr/bin/bootc' \
    "${root_dir}/custom/bootc/omarchy-bootc-update"
grep -Fq 'source /usr/lib/omarchy-bootc/update-common.sh' \
    "${root_dir}/custom/bootc/omarchy-bootc-update-available"
grep -Fq 'OMARCHY_BOOTC_BIN=/usr/bin/bootc' \
    "${root_dir}/custom/bootc/omarchy-bootc-update-available"
grep -Fq '/run/omarchy-bootc-update-trace/bootc' \
    "${root_dir}/custom/bootc/omarchy-bootc-update"
grep -Fq "/usr/bin/stat -c '%u:%a'" \
    "${root_dir}/custom/bootc/omarchy-bootc-update"
# This assertion preserves literal source syntax.
# shellcheck disable=SC2016
grep -Fq 'state_home="${user_home}/.local/state"' \
    "${root_dir}/custom/bootc/omarchy-bootc-update"
# This assertion preserves literal source syntax.
# shellcheck disable=SC2016
grep -Fq 'pending="${HOME}/.local/state/omarchy-bootc/pending-update"' \
    "${root_dir}/custom/bootc/omarchy-bootc-finalize"
grep -Fq 'OMARCHY_BOOTC_STATUS_HELPER=/usr/libexec/omarchy-bootc-status' \
    "${root_dir}/custom/bootc/omarchy-bootc-finalize"
grep -Fq 'run_as_root_noninteractive /usr/libexec/omarchy-bootc-clear-transaction' \
    "${root_dir}/custom/bootc/omarchy-bootc-finalize"
grep -Fq '%wheel ALL=(root) NOPASSWD: /usr/libexec/omarchy-bootc-status ""' \
    "${install_script}"
grep -Fq '%wheel ALL=(root) NOPASSWD: /usr/libexec/omarchy-bootc-clear-transaction ""' \
    "${install_script}"
grep -Fq '/usr/bin/bootc status --format=json' \
    "${root_dir}/custom/bootc/omarchy-bootc-status"
# This assertion preserves literal source syntax.
# shellcheck disable=SC2016
grep -Fq 'readlink -f "${omarchy_command}"' "${assembly}"
grep -Fq '!= /var/usrlocal/*' "${assembly}"
grep -Fq 'rm -f /var/usrlocal/bin/omarchy' "${install_script}"
# This assertion preserves literal source syntax.
# shellcheck disable=SC2016
grep -Fq 'dispatch_path="/usr/share/omarchy/bin/${command_name}"' "${install_script}"
grep -Fq 'for command_name in omarchy omarchy-update omarchy-update-available' \
    "${install_script}"
# This assertion preserves literal source syntax.
# shellcheck disable=SC2016
grep -Fq 'readlink "$dispatch_path")" == "/usr/bin/${command_name}"' "${install_script}"
# This assertion preserves literal source syntax.
# shellcheck disable=SC2016
grep -Fq 'readlink "$dispatch_path")" == "/usr/local/bin/${command_name}"' "${install_script}"
grep -Fq 'omarchy:summary=Stage the next bootc image' \
    "${root_dir}/custom/bootc/omarchy-update-wrapper"
grep -Fq 'omarchy:requires-sudo=true' \
    "${root_dir}/custom/bootc/omarchy-update-available-wrapper"
grep -Fq 'graphical PATH bypasses bootc dispatch' \
    "${root_dir}/build/acceptance-dependencies.sh"
grep -Fq 'graphical omarchy update did not execute the bootc wrapper' \
    "${root_dir}/build/acceptance-dependencies.sh"
grep -Fq 'graphical availability command did not execute the bootc helper' \
    "${root_dir}/build/acceptance-dependencies.sh"
grep -Fq 'omarchy update: unsupported option --unsupported' \
    "${root_dir}/build/acceptance-dependencies.sh"
grep -Fq 'Image availability accepts no arguments' \
    "${root_dir}/build/acceptance-dependencies.sh"
wrapper_status=0
wrapper_output="$(bash "${root_dir}/custom/bootc/omarchy-update-available-wrapper" \
    unexpected 2>&1)" || wrapper_status=$?
[[ "$wrapper_status" == 2 ]] || {
    echo "availability wrapper returned status $wrapper_status" >&2
    exit 1
}
grep -Fq 'Image availability accepts no arguments' <<<"$wrapper_output" || {
    echo 'availability wrapper did not report its argument boundary' >&2
    exit 1
}


printf 'update dispatch source contract passed\n'
