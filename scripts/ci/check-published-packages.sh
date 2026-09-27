#!/usr/bin/env bash
set -euo pipefail

# Run only in the disposable pinned Arch tool container. Read the manifest from
# the real published Omarchy package, not a substitute list or fixture.
# shellcheck disable=SC1091
source /ctx/build/lib/quattro-packages.sh
bash /ctx/build/configure-quattro-repositories.sh \
    /etc/pacman.conf /ctx/custom/pacman/quattro-repositories.conf
cat /ctx/custom/pacman/quattro-optional-resolver.conf >>/etc/pacman.conf
omarchy_key_file=/ctx/sources/omarchy-package-signing-key.asc
omarchy_key_fingerprint="$(cat /ctx/sources/omarchy-package-signing-key.fingerprint)"
[[ "${omarchy_key_fingerprint}" == 40DFB630FF42BCFFB047046CF0134EE680CAC571 ]]
printf '%s  %s\n' \
    "$(awk 'NR == 1 {print $1}' /ctx/sources/omarchy-package-signing-key.sha256)" \
    "${omarchy_key_file}" | sha256sum -c -
actual_omarchy_key_fingerprint="$(gpg --show-keys --with-colons "${omarchy_key_file}" \
    | awk -F: '$1 == "fpr" {print $10; exit}')"
[[ "${actual_omarchy_key_fingerprint}" == "${omarchy_key_fingerprint}" ]]
pacman-key --init
pacman-key --populate archlinux
pacman-key --add "${omarchy_key_file}"
pacman-key --lsign-key "${omarchy_key_fingerprint}"
pacman -Sy --noconfirm
expected_version="$(cat /ctx/sources/omarchy-quattro-version)"
published_version="$(pacman -Sddp --print-format '%v' omarchy)"
[[ "${published_version}" == "${expected_version}" ]] || {
    printf 'Expected Omarchy %s, repository has %s\n' "${expected_version}" "${published_version}" >&2
    exit 1
}
mkdir -p /tmp/omarchy-package
pacman -Swdd --noconfirm --cachedir /tmp/omarchy-package omarchy
mapfile -t packages < <(find /tmp/omarchy-package -type f ! -name '*.sig')
[[ ${#packages[@]} == 1 ]]
sha256sum "${packages[0]}"
tar -xOf "${packages[0]}" usr/share/omarchy/install/omarchy-other.packages \
    >/tmp/omarchy-other.packages
sha256sum /tmp/omarchy-other.packages

report=/tmp/optional-package-resolvability.txt
: >"${report}"
while IFS= read -r package; do
    resolve_quattro_optional_package /etc/pacman.conf "${package}" "${report}" \
        /ctx/sources /tmp/optional-archives
done < <(read_quattro_package_manifest /tmp/omarchy-other.packages)
grep -E '^(resolvable|resolvable-archive|unresolved|archive) ' "${report}"
verify_optional_resolution_report "${report}"
