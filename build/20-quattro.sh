#!/usr/bin/env bash
set -euo pipefail
phase=initialization
status=0
trap 'status=$?; printf "Quattro assembly failed (status %s, phase %s, line %s): %s\n" "$status" "$phase" "$LINENO" "$BASH_COMMAND" >&2; pacman -Q >&2 || true; exit "$status"' ERR

# shellcheck disable=SC1091
source /ctx/build/lib/quattro-packages.sh

OMARCHY_VERSION="${OMARCHY_VERSION:-4.0.4-1}"
OMARCHY_QUATTRO_REVISION="${OMARCHY_QUATTRO_REVISION:-c668141e9c42b13c80c9ca4ea108e11708c5e8a5}"
OMARCHY_SOURCE="/ctx/sources/omarchy-quattro.source"
OMARCHY_REVISION_FILE="/ctx/sources/omarchy-quattro.revision"
OMARCHY_VERSION_FILE="/ctx/sources/omarchy-quattro-version"
[[ "$(cat "${OMARCHY_REVISION_FILE}")" == "${OMARCHY_QUATTRO_REVISION}" ]]
[[ "$(cat "${OMARCHY_VERSION_FILE}")" == "${OMARCHY_VERSION}" ]]
OMARCHY_BASE_MANIFEST="/usr/share/omarchy/install/omarchy-base.packages"
OMARCHY_OTHER_MANIFEST="/usr/share/omarchy/install/omarchy-other.packages"
REPOSITORY_CONFIG="/ctx/custom/pacman/quattro-repositories.conf"
OPTIONAL_REPOSITORY_CONFIG="/ctx/custom/pacman/quattro-optional-resolver.conf"
HOOK_INVENTORY="/ctx/build/bootc-disabled-hooks.txt"
BOOTC_HOOK_DIR="/usr/share/omarchy-bootc/pacman-hooks"

# Preserve Bootcrew's bootc-specific pacman options and relocated database/cache
# paths while replacing only the repository sections with Quattro's topology.
phase=configure-repositories
bash /ctx/build/configure-quattro-repositories.sh /etc/pacman.conf "${REPOSITORY_CONFIG}"

# Pacman gives later HookDir entries precedence by filename. Install valid,
# never-triggering hooks under the exact evidenced names so official package
# files remain intact but cannot act on bootc-owned surfaces.
install -d -m 0755 "${BOOTC_HOOK_DIR}"
while IFS= read -r hook_name; do
    [[ -n "${hook_name}" ]]
    cat >"${BOOTC_HOOK_DIR}/${hook_name}" <<'EOF'
[Trigger]
Operation = Install
Type = Package
Target = __omarchy_bootc_never_matches__

[Action]
Description = bootc owns deployment and initramfs for this image
When = PostTransaction
Exec = /usr/bin/true
EOF
done <"${HOOK_INVENTORY}"
sed -i "/^\[options\]$/a HookDir = ${BOOTC_HOOK_DIR}" /etc/pacman.conf

phase=refresh-signing-keys
pacman-key --init
pacman-key --populate archlinux
omarchy_key_file=/ctx/sources/omarchy-package-signing-key.asc
omarchy_key_fingerprint="$(cat /ctx/sources/omarchy-package-signing-key.fingerprint)"
[[ "${omarchy_key_fingerprint}" == 40DFB630FF42BCFFB047046CF0134EE680CAC571 ]]
printf '%s  %s\n' \
    "$(awk 'NR == 1 {print $1}' /ctx/sources/omarchy-package-signing-key.sha256)" \
    "${omarchy_key_file}" | sha256sum -c -
omarchy_key_verification_home=/tmp/omarchy-key-verification
install -d -m 0700 "${omarchy_key_verification_home}"
actual_omarchy_key_fingerprint="$(gpg --homedir "${omarchy_key_verification_home}" --show-keys --with-colons "${omarchy_key_file}" \
    | awk -F: '$1 == "fpr" {print $10; exit}')"
[[ "${actual_omarchy_key_fingerprint}" == "${omarchy_key_fingerprint}" ]]
pacman-key --add "${omarchy_key_file}"
pacman-key --lsign-key "${omarchy_key_fingerprint}"
install -D -m 0644 /ctx/sources/omarchy-package-signing-key.fingerprint \
    /usr/share/omarchy-bootc/sources/omarchy-package-signing-key.fingerprint
install -D -m 0644 /ctx/sources/omarchy-package-signing-key.source \
    /usr/share/omarchy-bootc/sources/omarchy-package-signing-key.source
phase=upgrade-stable-base
pacman -Syyu --noconfirm
phase=install-omarchy-release
pacman -S --noconfirm --needed omarchy-keyring
pacman-key --populate omarchy

# Bootcrew starts with /usr/local mapped into mutable state. Materialize it as
# an image-owned directory and keep it that way so Omarchy CLI dispatch never
# resolves through mutable /var/usrlocal.
[[ -L /usr/local ]]
[[ "$(readlink /usr/local)" == "../var/usrlocal" ]]
rm /usr/local
install -d -m 0755 /usr/local

phase=install-quattro-packages
pacman -S --noconfirm --needed omarchy-settings omarchy

while IFS= read -r hook_name; do
    [[ -f "${BOOTC_HOOK_DIR}/${hook_name}" ]]
    grep -Fq 'Target = __omarchy_bootc_never_matches__' "${BOOTC_HOOK_DIR}/${hook_name}"
done <"${HOOK_INVENTORY}"

[[ "$(pacman -Q omarchy | awk '{ print $2 }')" == "${OMARCHY_VERSION}" ]]
[[ "$(pacman -Q omarchy-settings | awk '{ print $2 }')" == "${OMARCHY_VERSION}" ]]

mapfile -t base_packages < <(read_quattro_package_manifest "${OMARCHY_BASE_MANIFEST}")
mapfile -t other_packages < <(read_quattro_package_manifest "${OMARCHY_OTHER_MANIFEST}")

[[ ${#base_packages[@]} -gt 0 ]]
[[ ${#other_packages[@]} -gt 0 ]]

phase=install-base-closure
pacman -S --noconfirm --needed "${base_packages[@]}"
phase=register-package-system-users
install -D -m 0644 /ctx/build/cups-browsed.sysusers.conf \
    /usr/lib/sysusers.d/cups-browsed.conf
systemd-sysusers
getent passwd cups-browsed >/dev/null
getent group cups-browsed >/dev/null

# The optional manifest contains mutually exclusive hardware packages. Resolve
# each dependency graph and retain the result without installing it wholesale.
# T2 packages use the supplemental repository shipped by the pinned official
# ISO, but that repository is applied only to this resolver copy so the proven
# Omarchy-stable foundation topology remains unchanged.
install -d -m 0755 /usr/share/omarchy-bootc
install -D -m 0644 "${OMARCHY_SOURCE}" /usr/share/omarchy-bootc/sources/omarchy-quattro.source
install -D -m 0644 "${OMARCHY_REVISION_FILE}" /usr/share/omarchy-bootc/sources/omarchy-quattro.revision
install -D -m 0644 "${OMARCHY_VERSION_FILE}" /usr/share/omarchy-bootc/sources/omarchy-quattro-version
printf '%s\n' "${OMARCHY_QUATTRO_REVISION}" > /usr/share/omarchy-bootc/sources/omarchy-quattro-resolved-revision

optional_report=/usr/share/omarchy-bootc/optional-package-resolvability.txt
optional_pacman_config=/tmp/quattro-optional-resolver.conf
phase=resolve-optional-packages
cp /etc/pacman.conf "${optional_pacman_config}"
printf '\n' >>"${optional_pacman_config}"
cat "${OPTIONAL_REPOSITORY_CONFIG}" >>"${optional_pacman_config}"
pacman --config "${optional_pacman_config}" -Sy --noconfirm
: >"${optional_report}"
for package in "${other_packages[@]}"; do
    resolve_quattro_optional_package "${optional_pacman_config}" "${package}" \
        "${optional_report}" /ctx/sources /tmp/optional-archives
done
verify_optional_resolution_report "${optional_report}"
optional_database_path="$(pacman-conf \
    --config "${optional_pacman_config}" DBPath)"
remove_optional_repository_database \
    "${optional_database_path}" \
    arch-mact2

for required in \
    /usr/bin/omarchy \
    /usr/bin/omarchy-menu \
    /usr/bin/omarchy-theme-list \
    /usr/share/omarchy/shell \
    /usr/share/omarchy/themes \
    /usr/share/sddm/themes/omarchy \
    /usr/local/share/wayland-sessions/omarchy.desktop; do
    [[ -e "${required}" ]]
done

mapfile -t usrlocal_files < <(find /usr/local -type f -print | sort)
[[ ${#usrlocal_files[@]} -eq 2 ]]
[[ "${usrlocal_files[0]}" == "/usr/local/bin/mkinitcpio" ]]
[[ "${usrlocal_files[1]}" == "/usr/local/share/wayland-sessions/omarchy.desktop" ]]
canonical_session=/usr/share/omarchy/default/wayland-sessions/omarchy.desktop
projected_session=/usr/share/wayland-sessions/omarchy.desktop
cmp --silent "${usrlocal_files[1]}" "${canonical_session}"
install -Dm644 "${canonical_session}" "${projected_session}"
cmp --silent "${projected_session}" "${canonical_session}"
phase=record-package-provenance
provenance_dir=/usr/share/omarchy-bootc
pacman -Q >"${provenance_dir}/quattro-package-manifest.txt"
pacman -Qi >"${provenance_dir}/quattro-package-provenance.txt"
pacman -Qm >"${provenance_dir}/quattro-foreign-package-manifest.txt"
cp /etc/pacman.conf "${provenance_dir}/pacman.conf"
find /var/lib/pacman/sync -maxdepth 1 -type f -name '*.db*' -print0 \
    | sort -z \
    | xargs -0 -r sha256sum >"${provenance_dir}/repository-database-sha256sums.txt"

phase=clean-pacman-cache
pacman -Scc --noconfirm

phase=verify-upstream-cli
[[ -d /usr/local && ! -L /usr/local ]]
[[ "$(command -v omarchy)" == /usr/bin/omarchy ]]
[[ "$(readlink -f /usr/bin/omarchy)" == /usr/bin/omarchy ]]
