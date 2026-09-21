#!/usr/bin/env bash
set -euo pipefail

# Run only in the disposable pinned Arch tool container. Read the manifest from
# the real published Omarchy package, not a substitute list or fixture.
# shellcheck disable=SC1091
source /ctx/build/lib/quattro-packages.sh
bash /ctx/build/configure-quattro-repositories.sh \
    /etc/pacman.conf /ctx/custom/pacman/quattro-repositories.conf
cat /ctx/custom/pacman/quattro-optional-resolver.conf >>/etc/pacman.conf
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
