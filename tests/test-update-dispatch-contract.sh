#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
install_script="${root_dir}/build/install-bootc-update.sh"
wrapper="${root_dir}/custom/bootc/omarchy-wrapper"
assembly="${root_dir}/build/20-quattro.sh"

grep -Fq 'install -m 0755 "$lib/omarchy-wrapper" /usr/local/bin/omarchy' "${install_script}"
grep -Fq 'PATH=/usr/local/bin:/usr/bin:/bin command -v omarchy' "${install_script}"
grep -Fq 'export PATH=/usr/local/bin:$PATH' "${install_script}"
grep -Fq 'var/usrlocal/bin/$stale' "${install_script}"
grep -Fq 'update|up)' "${wrapper}"
grep -Fq 'exec /usr/lib/omarchy-bootc/omarchy-bootc-update' "${wrapper}"
grep -Fq 'exec /usr/bin/omarchy' "${wrapper}"
grep -Fq 'readlink -f "${omarchy_command}"' "${assembly}"
grep -Fq '!= /var/usrlocal/*' "${assembly}"
! grep -Fq '/var/usrlocal/bin/omarchy' "${install_script}"

printf 'update dispatch source contract passed\n'
