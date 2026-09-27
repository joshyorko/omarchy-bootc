#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINERFILE="${ROOT_DIR}/Containerfile"
QUATTRO_BUILD="${ROOT_DIR}/build/20-quattro.sh"
BOOT_OWNERSHIP="${ROOT_DIR}/build/30-bootc-ownership.sh"
PACKAGE_HELPERS="${ROOT_DIR}/build/lib/quattro-packages.sh"
INITRAMFS_HELPERS="${ROOT_DIR}/build/lib/bootc-initramfs.sh"
PAYLOAD_VERIFIER="${ROOT_DIR}/build/verify-quattro-payload.sh"
REPOSITORY_CONFIG="${ROOT_DIR}/custom/pacman/quattro-repositories.conf"
OPTIONAL_REPOSITORY_CONFIG="${ROOT_DIR}/custom/pacman/quattro-optional-resolver.conf"
HOOK_INVENTORY="${ROOT_DIR}/build/bootc-disabled-hooks.txt"
FINAL_IMAGE_VERIFIER="${ROOT_DIR}/build/verify-publishable-image.sh"
ACCEPTANCE_NODE_STAGER="${ROOT_DIR}/build/stage-acceptance-node.sh"
ACCEPTANCE_FIRSTBOOT="${ROOT_DIR}/build/acceptance-firstboot.sh"
ADOPTION_SCRIPT="${ROOT_DIR}/custom/first-boot/omarchy-adopt-existing-user.sh"
ADOPTION_ROLLBACK="${ROOT_DIR}/custom/first-boot/omarchy-adoption-rollback.sh"
ADOPTION_SERVICE="${ROOT_DIR}/systemd/system/omarchy-adopt-existing-user.service"
BASE_BUILD="${ROOT_DIR}/build/10-base.sh"
SERVICES_BUILD="${ROOT_DIR}/build/30-services.sh"
TRANSITION_SCRIPT="${ROOT_DIR}/transition/omarchy-transition.sh"
RUNTIME_SCRIPT="${ROOT_DIR}/scripts/ci/candidate-runtime.sh"
BOOTCREW_REVISION_FILE="${ROOT_DIR}/vendor/bootcrew/REVISION"
BOOTC_REVISION_FILE="${ROOT_DIR}/vendor/bootcrew/BOOTC_REVISION"
BOOTC_VERSION_FILE="${ROOT_DIR}/vendor/bootcrew/BOOTC_VERSION"
BOOTCREW_SOURCE_FILE="${ROOT_DIR}/vendor/bootcrew/SOURCE"
BOOTC_SOURCE_FILE="${ROOT_DIR}/vendor/bootcrew/BOOTC_SOURCE"
BOOTCREW_CHECKSUMS="${ROOT_DIR}/vendor/bootcrew/SHA256SUMS"
REPOSITORY_CONFIGURATOR="${ROOT_DIR}/build/configure-quattro-repositories.sh"
DESIGN_CONTRACT="${ROOT_DIR}/docs/superpowers/specs/2026-08-26-omarchy-quattro-bootc-design.md"
INSTALLER_CONTRACT="${ROOT_DIR}/docs/installer-parity-contract.md"
TRANSITION_CONTRACT="${ROOT_DIR}/docs/transition-contract.md"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

if grep -Eqi '^[[:space:]]*FROM[[:space:]].*(ghcr\.io/)?bootcrew/' "${CONTAINERFILE}"; then
    fail 'published Bootcrew package payload must not seed the final image'
fi
grep -Fq 'ARG BOOTCREW_MONO_REVISION="5f048fa65a94daefc814d3cdd941d8d1e113c09e"' \
    "${CONTAINERFILE}" || fail 'Containerfile does not pin the reviewed Bootcrew mono revision'
grep -Fq 'ARG BOOTC_REVISION="fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60"' \
    "${CONTAINERFILE}" || fail 'Containerfile does not pin the reviewed bootc revision'
grep -Fq 'ARG BOOTC_VERSION="v1.16.13"' "${CONTAINERFILE}" \
    || fail 'Containerfile does not pin bootc v1.16.13'
grep -Fq 'docker.io/archlinux/archlinux:latest@sha256:0de35fe2ee793494ccfc99b202f6b30215b078baf2b082e9ccb027840c534fc1' \
    "${CONTAINERFILE}" || fail 'disposable Arch bootstrap image is not pinned'
grep -Fq 'FROM scratch AS stable-base' "${CONTAINERFILE}" \
    || fail 'Omarchy-stable root is not constructed from an empty filesystem'
grep -Fq -- '--root /stable-root' "${CONTAINERFILE}" \
    || fail 'Omarchy-stable root is not populated from an empty pacman root'
if grep -Fq 'pacman -Syyuu' "${CONTAINERFILE}"; then
    fail 'bulk downgrade of an already-built root is forbidden'
fi
[[ -f "${BOOTCREW_REVISION_FILE}" ]] || fail 'pinned Bootcrew mono revision is missing'
[[ "$(<"${BOOTCREW_REVISION_FILE}")" == '5f048fa65a94daefc814d3cdd941d8d1e113c09e' ]] \
    || fail 'Bootcrew mono revision differs from the reviewed construction'
[[ -f "${BOOTCREW_SOURCE_FILE}" ]] || fail 'Bootcrew mono source URL is missing'
[[ "$(<"${BOOTCREW_SOURCE_FILE}")" == 'https://github.com/bootcrew/mono.git' ]] \
    || fail 'Bootcrew mono source URL differs from the reviewed construction'
[[ -f "${BOOTC_VERSION_FILE}" && "$(<"${BOOTC_VERSION_FILE}")" == 'v1.16.13' ]] \
    || fail 'bootc version record differs from v1.16.13'
[[ -f "${BOOTC_REVISION_FILE}" ]] || fail 'pinned bootc source revision is missing'
[[ "$(<"${BOOTC_REVISION_FILE}")" == 'fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60' ]] \
    || fail 'bootc source revision differs from v1.16.13'
[[ -f "${BOOTC_SOURCE_FILE}" ]] || fail 'bootc source URL is missing'
[[ "$(<"${BOOTC_SOURCE_FILE}")" == 'https://github.com/bootc-dev/bootc.git' ]] \
    || fail 'bootc source URL differs from upstream bootc-dev/bootc'
[[ -f "${BOOTCREW_CHECKSUMS}" ]] || fail 'vendored Bootcrew source checksums are missing'
(cd "${ROOT_DIR}/vendor/bootcrew" && sha256sum --check --status SHA256SUMS) \
    || fail 'vendored Bootcrew construction differs from the pinned source snapshot'
# shellcheck disable=SC2016
grep -Fq 'BOOTC_REVISION="${BOOTC_REVISION:?}"' "${ROOT_DIR}/vendor/bootcrew/shared/build.sh" \
    || fail 'Bootcrew build does not require an explicit bootc revision'
grep -Fq 'BOOTC_SOURCE="${BOOTC_SOURCE:?}"' "${ROOT_DIR}/vendor/bootcrew/shared/build.sh" \
    || fail 'Bootcrew build does not require an explicit bootc source'
if grep -Eq 'git[[:space:]]+clone' "${ROOT_DIR}/vendor/bootcrew/shared/build.sh"; then
    fail 'bootc source must not use an unpinned git clone'
fi
grep -Fq 'git remote add origin "${BOOTC_SOURCE}"' "${ROOT_DIR}/vendor/bootcrew/shared/build.sh" \
    || fail 'bootc fetch does not consume the recorded source URL'
grep -Fq '[[ "$(git rev-parse HEAD)" == "${BOOTC_REVISION}" ]]' \
    "${ROOT_DIR}/vendor/bootcrew/shared/build.sh" \
    || fail 'bootc checkout does not verify the fetched commit exactly'
grep -Fq 'org.opencontainers.image.bootcrew.revision="${BOOTCREW_MONO_REVISION}"' "${CONTAINERFILE}" \
    || fail 'final image does not record the Bootcrew source revision'
grep -Fq 'org.opencontainers.image.bootc.revision' "${CONTAINERFILE}" \
    || fail 'final image does not record the bootc source revision'
grep -Fq 'test "$(cat /ctx/REVISION)" = "${BOOTCREW_MONO_REVISION}"' "${CONTAINERFILE}" \
    || fail 'build does not bind the Bootcrew revision record to the construction argument'
grep -Fq 'test "$(cat /ctx/BOOTC_REVISION)" = "${BOOTC_REVISION}"' "${CONTAINERFILE}" \
    || fail 'build does not bind the bootc revision record to the construction argument'
[[ -f "${REPOSITORY_CONFIGURATOR}" ]] || fail 'repository topology configurator is missing'
if grep -Eiq 'SigLevel[[:space:]]*=[[:space:]]*(Optional|Never)|TrustAll|Include[[:space:]]*=[[:space:]]*/etc/pacman.d/mirrorlist' "${REPOSITORY_CONFIG}"; then
    fail 'Quattro repository configuration permits unsigned packages or arbitrary Arch fallback'
fi
grep -Fq 'SigLevel = Required DatabaseOptional' "${REPOSITORY_CONFIG}" \
    || fail 'Omarchy packages are not signature-required'
grep -Fq 'stable-mirror.omarchy.org/$repo/os/$arch' "${REPOSITORY_CONFIG}" \
    || fail 'Quattro repositories do not use the stable Omarchy mirror'

[[ -f "${QUATTRO_BUILD}" ]] || fail 'build/20-quattro.sh is missing'
[[ -f "${BOOT_OWNERSHIP}" ]] || fail 'build/30-bootc-ownership.sh is missing'

grep -Fq 'OMARCHY_VERSION="${OMARCHY_VERSION:-4.0.4-1}"' "${QUATTRO_BUILD}" \
    || fail 'official Omarchy package version is not pinned to current 4.0.4-1'
grep -Fq 'c668141e9c42b13c80c9ca4ea108e11708c5e8a5' "${QUATTRO_BUILD}" \
    || fail 'current Omarchy Quattro source revision is not recorded'
grep -Fq '/usr/share/omarchy/install/omarchy-base.packages' "${QUATTRO_BUILD}" \
    || fail 'Quattro base package manifest is not consumed from the official package'
grep -Fq '/usr/lib/sysusers.d/cups-browsed.conf' "${QUATTRO_BUILD}" \
    || fail 'cups-browsed does not have an image-owned sysusers declaration'
grep -Fq 'getent passwd cups-browsed' "${QUATTRO_BUILD}" \
    || fail 'cups-browsed system user is not verified after sysusers'
grep -Fq 'getent group cups-browsed' "${QUATTRO_BUILD}" \
    || fail 'cups-browsed system group is not verified after sysusers'
grep -Fq '/usr/share/omarchy/install/omarchy-other.packages' "${QUATTRO_BUILD}" \
    || fail 'Quattro optional package manifest is not consumed from the official package'
grep -Fq '/usr/share/omarchy-bootc/optional-package-resolvability.txt' "${QUATTRO_BUILD}" \
    || fail 'Quattro optional dependency resolvability is not recorded'

for wrapper_root in \
    "${ROOT_DIR}/custom/omarchy-overrides" \
    "${ROOT_DIR}/custom/pneuma" \
    "${ROOT_DIR}/custom/omedora"; do
    [[ ! -e "${wrapper_root}" ]] || fail "compatibility wrapper payload exists: ${wrapper_root}"
done

for unit in \
    limine-snapper-sync.service \
    snapper-cleanup.timer \
    snapper-timeline.timer; do
    grep -Fq "${unit}" "${BOOT_OWNERSHIP}" \
        || fail "boot ownership script does not neutralize ${unit}"
done

expected_hook_inventory='90-mkinitcpio-install.hook
10-limine-snapper-lock.hook
60-limine-mkinitcpio-remove-pre.hook
80-limine-efi-deploy.hook
90-limine-mkinitcpio-remove-post.hook'
[[ "$(<"${HOOK_INVENTORY}")" == "${expected_hook_inventory}" ]] \
    || fail 'disabled-hook inventory differs from observed collision evidence'
grep -Fq 'bootc-disabled-hooks.txt' "${QUATTRO_BUILD}" \
    || fail 'Quattro build does not consume the disabled-hook inventory'
if grep -RqsE '(^|/)(omarchy-update|omarchy-pkg-|omarchy-launch-browser)$' \
    "${ROOT_DIR}/custom"; then
    fail 'local replacement for an upstream omarchy command exists'
fi

[[ -f "${PACKAGE_HELPERS}" ]] || fail 'Quattro package manifest helper is missing'
[[ -f "${INITRAMFS_HELPERS}" ]] || fail 'bootc initramfs report verifier is missing'
[[ -f "${PAYLOAD_VERIFIER}" ]] || fail 'Quattro package provenance verifier is missing'
[[ -f "${REPOSITORY_CONFIG}" ]] || fail 'official Quattro repository topology is missing'
[[ -f "${OPTIONAL_REPOSITORY_CONFIG}" ]] \
    || fail 'official Quattro optional resolver topology is missing'
[[ -f "${HOOK_INVENTORY}" ]] || fail 'disabled-hook evidence inventory is missing'
[[ -f "${FINAL_IMAGE_VERIFIER}" ]] || fail 'publishable-image credential verifier is missing'
[[ -f "${ACCEPTANCE_NODE_STAGER}" ]] || fail 'official ISO Node staging input is missing from acceptance'
[[ -f "${ACCEPTANCE_FIRSTBOOT}" ]] || fail 'acceptance first-boot finalization is missing'
[[ -f "${ADOPTION_SCRIPT}" ]] || fail 'cross-distro adoption script is missing'
[[ -f "${ADOPTION_ROLLBACK}" ]] || fail 'cross-distro adoption rollback is missing'
[[ -f "${ADOPTION_SERVICE}" ]] || fail 'cross-distro adoption service is missing'
[[ -x "${TRANSITION_SCRIPT}" ]] || fail 'state-aware transition helper is missing or not executable'

grep -Fq 'FROM quattro-base AS acceptance' "${CONTAINERFILE}" \
    || fail 'acceptance identity is not isolated in its own image target'
grep -Fq 'FROM quattro-base AS final' "${CONTAINERFILE}" \
    || fail 'publishable final image is not separated from acceptance identity'
grep -Fq 'omarchy-provision-user --first-install' "${ACCEPTANCE_FIRSTBOOT}" \
    || fail 'acceptance user does not run official Quattro finalization'
grep -Fq '.local/state/omarchy/done/finalize-user' "${ACCEPTANCE_FIRSTBOOT}" \
    || fail 'acceptance user finalization marker is not proved'

if grep -Fq 'Create default POC user' "${BASE_BUILD}" ||
    grep -Fq "omarchy:omarchy" "${BASE_BUILD}"; then
    fail 'publishable image still creates the POC omarchy user or password'
fi
grep -Fq 'omarchy-adopt-existing-user.service' "${SERVICES_BUILD}" \
    || fail 'normal image does not enable the bounded adoption service'
grep -Fq 'systemctl mask omarchy-adopt-existing-user.service' \
    "${ROOT_DIR}/build/25-quattro-user.sh" \
    || fail 'acceptance image does not isolate itself from adoption'
grep -Fq 'transition-ctx' "${CONTAINERFILE}" \
    || fail 'state-aware transition helper is not included in the image context'
grep -Fq '/var/lib/omarchy-bootc/installer-origin' "${ADOPTION_SCRIPT}" \
    || fail 'adoption script does not bypass fresh ISO installs'
grep -Fq 'Before=display-manager.service' "${ADOPTION_SERVICE}" \
    || fail 'adoption does not complete before the login manager'
grep -Fq 'Requires=omarchy-adopt-existing-user.service' "${ROOT_DIR}/Containerfile" \
    || fail 'display manager is not gated on adoption completion'
if grep -Fq 'ConditionPathExists=' "${ADOPTION_SERVICE}"; then
    fail 'adoption completion gate is weakened by a conditional service'
fi
for adoption_surface in \
    'find "$HOME_ROOT"' \
    'systemd-ask-password' \
    'omarchy-provision-user' \
    'managed_paths' \
    'state.env'; do
    grep -Fq "${adoption_surface}" "${ADOPTION_SCRIPT}" \
        || fail "adoption script is missing ${adoption_surface}"
done
grep -Fq 'rollback-current' "${ADOPTION_ROLLBACK}" ||
    grep -Fq 'rollback-current' "${ADOPTION_SCRIPT}" \
    || fail 'adoption rollback does not preserve post-adoption changes'
grep -Fq 'omarchy-adoption-rollback' "${ADOPTION_ROLLBACK}" \
    || fail 'adoption rollback command identity is missing'
if grep -Fq 'cp -a -n /usr/share/omarchy/skel' "${ADOPTION_SCRIPT}" ||
    grep -Fq 'rm -rf "${HYPR_CONF_DIR}"' "${ADOPTION_SCRIPT}"; then
    fail 'cross-distro adoption still blindly replays image skeleton state'
fi

[[ -f "${INSTALLER_CONTRACT}" ]] || fail 'official Omarchy installer parity contract is missing'
[[ -f "${TRANSITION_CONTRACT}" ]] || fail 'cross-distro transition contract is missing'
grep -Fq 'bootc switch' "${TRANSITION_CONTRACT}" \
    || fail 'transition contract does not retain bootc switch as the image operation'
grep -Fq 'Bluefin' "${TRANSITION_CONTRACT}" \
    || fail 'transition contract does not define the Bluefin source profile'
grep -Fq 'Dakota' "${TRANSITION_CONTRACT}" \
    || fail 'transition contract does not define the Dakota source profile'
grep -Fq 'password hashes' "${TRANSITION_CONTRACT}" \
    || fail 'transition contract does not exclude credentials from captured state'
grep -Fq '86c07785cb0f63be78edb1349843d5817b5c0e66' "${INSTALLER_CONTRACT}" \
    || fail 'current official Omarchy Quattro ISO source revision is not pinned'
grep -Fq 'bootc install to-filesystem' "${INSTALLER_CONTRACT}" \
    || fail 'installer contract does not select the external-installer bootc seam'
grep -Fq 'ostree admin --sysroot=/mnt --print-current-dir' "${INSTALLER_CONTRACT}" \
    || fail 'installer contract does not define target deployment discovery'
grep -Fq 'bootc install finalize' "${INSTALLER_CONTRACT}" \
    || fail 'installer contract does not require bootc finalization before unmount'
grep -Fq 'omarchy-provision-user --first-install' "${INSTALLER_CONTRACT}" \
    || fail 'installer contract does not preserve official user finalization'
grep -Fq 'same pinned upstream acceptance harness' "${INSTALLER_CONTRACT}" \
    || fail 'installer contract does not require behavioral comparison with upstream'
grep -Fq 'additive installer variant' "${INSTALLER_CONTRACT}" \
    || fail 'Quattro installer is not explicitly additive to Dudley installer variants'
grep -Fq 'must not replace, mutate, or regress any existing Dudley, Dakota, or Bluefin installer variant' \
    "${INSTALLER_CONTRACT}" \
    || fail 'existing prescribed installer variants lack a non-regression requirement'
grep -Fq 'Branding is deferred' "${INSTALLER_CONTRACT}" \
    || fail 'installer branding must wait for upstream parity proof'
grep -Fq 'docs/installer-parity-contract.md' "${DESIGN_CONTRACT}" \
    || fail 'architecture design does not incorporate the installer parity contract'

for source_file in \
    sources/omarchy-quattro.source \
    sources/omarchy-quattro.revision \
    sources/omarchy-quattro-version \
    sources/omarchy-package-signing-key.asc \
    sources/omarchy-package-signing-key.fingerprint \
    sources/omarchy-package-signing-key.sha256 \
    sources/omarchy-package-signing-key.source \
    sources/omarchy-iso-quattro.source \
    sources/omarchy-iso-quattro.revision; do
    [[ -f "${ROOT_DIR}/${source_file}" ]] || fail "source record missing: ${source_file}"
done
[[ "$(<"${ROOT_DIR}/sources/omarchy-quattro.revision")" == 'c668141e9c42b13c80c9ca4ea108e11708c5e8a5' ]] ||
    fail 'Omarchy source record is not the v4.0.4 release commit'
[[ "$(<"${ROOT_DIR}/sources/omarchy-iso-quattro.revision")" == '86c07785cb0f63be78edb1349843d5817b5c0e66' ]] ||
    fail 'Omarchy ISO Quattro reference does not match the live upstream pin'
[[ "$(<"${ROOT_DIR}/sources/omarchy-quattro-version")" == '4.0.4-1' ]] \
    || fail 'frozen Omarchy package version does not match the published stable release'
[[ "$(<"${ROOT_DIR}/sources/omarchy-package-signing-key.fingerprint")" == '40DFB630FF42BCFFB047046CF0134EE680CAC571' ]] \
    || fail 'Omarchy signing key fingerprint changed'
(cd "${ROOT_DIR}/sources" && sha256sum --check --status omarchy-package-signing-key.sha256) \
    || fail 'Omarchy signing key bytes differ from the pinned checksum'
for update_surface in \
    custom/bootc/omarchy-bootc-common.sh \
    custom/bootc/omarchy-bootc-update \
    custom/bootc/omarchy-bootc-update-available \
    custom/bootc/omarchy-bootc-finalize \
    build/install-bootc-update.sh; do
    [[ -f "${ROOT_DIR}/${update_surface}" ]] || fail "bootc update surface missing: ${update_surface}"
done
grep -Fq 'bootc upgrade --check' "${ROOT_DIR}/custom/bootc/omarchy-bootc-update" ||
    fail 'update bridge does not perform a bootc metadata check'
grep -Fq 'bootc upgrade' "${ROOT_DIR}/custom/bootc/omarchy-bootc-update" ||
    fail 'update bridge does not stage through bootc'
if grep -Fq 'pacman -Syu' "${ROOT_DIR}/custom/bootc/omarchy-bootc-update"; then
    fail 'bootc update bridge invokes live pacman'
fi
grep -Fq 'target_resolved_digest' "${TRANSITION_SCRIPT}" ||
    fail 'transition does not persist exact target digest'
grep -Fq 'omarchy-bootc.accepted-candidate/v1' "${RUNTIME_SCRIPT}" \
    || fail 'runtime acceptance does not emit a machine-readable accepted candidate receipt'
grep -Fq 'publishable:false' "${RUNTIME_SCRIPT}" \
    || fail 'unsigned local candidate receipt is not distinguished from a publishable image'

for required_validation_input in \
    build/lib/bootc-initramfs.sh \
    custom/pacman/quattro-optional-resolver.conf \
    docs/installer-parity-contract.md \
    vendor/bootcrew/SOURCE \
    vendor/bootcrew/BOOTC_SOURCE \
    vendor/bootcrew/SHA256SUMS; do
    grep -Fq "${required_validation_input}" "${ROOT_DIR}/Justfile" \
        || fail "just validate does not require ${required_validation_input}"
done

if grep -Fq 'BOOTC_REF=v1.13.0' "${ROOT_DIR}/docs/technical-status.md"; then
    fail 'technical status still describes the obsolete unpinned bootc source input'
fi
if grep -Fq 'OCI build on `archlinux:base`' "${ROOT_DIR}/README.md"; then
    fail 'README still describes the obsolete rolling Arch final base'
fi
if grep -RqsE 'BOOTC_REF|v1\.13\.0|archlinux:base' \
    "${ROOT_DIR}/README.md" "${ROOT_DIR}/docs"; then
    fail 'documentation still contains the superseded rolling or ref-based foundation contract'
fi

# shellcheck disable=SC2016
expected_repository_config='[core]
# Do not add Arch mirrorlist entries as fallback: missing Quattro packages must
# fail resolution instead of silently mixing arbitrary rolling Arch packages.
Server = https://stable-mirror.omarchy.org/$repo/os/$arch

[extra]
Server = https://stable-mirror.omarchy.org/$repo/os/$arch

[multilib]
Server = https://stable-mirror.omarchy.org/$repo/os/$arch

[omarchy]
SigLevel = Required DatabaseOptional
Server = https://pkgs.omarchy.org/stable/$arch'
[[ "$(<"${REPOSITORY_CONFIG}")" == "${expected_repository_config}" ]] \
    || fail 'Quattro repository topology does not match the fail-closed trusted source set'

expected_optional_repository_config='[arch-mact2]
Server = https://mirror.funami.tech/arch-mact2/os/x86_64
Server = https://github.com/NoaHimesaka1873/arch-mact2-mirror/releases/download/release
SigLevel = Never'
[[ "$(<"${OPTIONAL_REPOSITORY_CONFIG}")" == "${expected_optional_repository_config}" ]] \
    || fail 'Quattro optional resolver topology differs from the pinned official ISO'

grep -Fq 'cmp --silent' "${QUATTRO_BUILD}" \
    || fail '/usr/local session projection is not byte-identity checked'
grep -Fq 'bootc projection exception' "${PAYLOAD_VERIFIER}" \
    || fail 'provenance report does not name the /usr/local projection exception'

grep -Fxq '90-mkinitcpio-install.hook' "${HOOK_INVENTORY}" \
    || fail 'mkinitcpio hook is absent from disabled-hook inventory'
if grep -Fqi 'kernel-modules-hook' "${HOOK_INVENTORY}"; then
    fail 'kernel-modules-hook must remain enabled pending lifecycle evidence'
fi
# shellcheck disable=SC1090
source "${PACKAGE_HELPERS}"
# shellcheck disable=SC1090
source "${INITRAMFS_HELPERS}"

declare -F verify_optional_resolution_report >/dev/null \
    || fail 'optional package resolution report verifier is missing'
declare -F remove_optional_repository_database >/dev/null \
    || fail 'optional repository database cleanup helper is missing'

fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT
printf '%s\n' \
    '# upstream comment' \
    '' \
    'hyprland' \
    '  quickshell  ' \
    '# another comment' \
    'sddm' \
    >"${fixture_dir}/packages"

mapfile -t parsed_packages < <(read_quattro_package_manifest "${fixture_dir}/packages")
expected_packages=(hyprland quickshell sddm)
[[ "${parsed_packages[*]}" == "${expected_packages[*]}" ]] \
    || fail "manifest parser returned: ${parsed_packages[*]}"

printf '%s\n' \
    'resolvable hyprland' \
    'hyprland 0.56.2-1' \
    'unresolved linux-t2' \
    'error: target not found: linux-t2' \
    >"${fixture_dir}/optional-resolution"
if verify_optional_resolution_report "${fixture_dir}/optional-resolution" 2>"${fixture_dir}/optional-error"; then
    fail 'optional resolver accepted an unresolved authoritative package'
fi
grep -Fq 'unresolved linux-t2' "${fixture_dir}/optional-error" \
    || fail 'optional resolver hid the failed package from build logs'

printf '%s\n' \
    'resolvable hyprland' \
    'hyprland 0.56.2-1' \
    'resolvable linux-t2' \
    'linux-t2 7.1.8.arch1-3' \
    >"${fixture_dir}/optional-resolution"
verify_optional_resolution_report "${fixture_dir}/optional-resolution" \
    || fail 'optional resolver rejected a fully resolved authoritative report'

# A corrupt archived payload must never reach the native package resolver.
(
    curl() { printf 'corrupt archive\n' >"${@: -1}"; }
    pacman() { touch "${fixture_dir}/unexpected-archive-resolution"; }
    if resolve_archived_apple_firmware "${OPTIONAL_REPOSITORY_CONFIG}" \
        "${ROOT_DIR}/sources" "${fixture_dir}/archives" 2>"${fixture_dir}/archive-error"; then
        fail 'archived firmware accepted a checksum mismatch'
    fi
    [[ ! -e "${fixture_dir}/unexpected-archive-resolution" ]] \
        || fail 'unchecked firmware archive reached pacman'
    grep -Fq 'did NOT match' "${fixture_dir}/archive-error" \
        || fail 'archive corruption test did not reach the checksum guard'
)

install -d "${fixture_dir}/pacman/sync"
touch \
    "${fixture_dir}/pacman/sync/arch-mact2.db" \
    "${fixture_dir}/pacman/sync/arch-mact2.db.sig" \
    "${fixture_dir}/pacman/sync/core.db"
remove_optional_repository_database \
    "${fixture_dir}/pacman/" \
    arch-mact2
[[ ! -e "${fixture_dir}/pacman/sync/arch-mact2.db" ]]
[[ ! -e "${fixture_dir}/pacman/sync/arch-mact2.db.sig" ]]
[[ -e "${fixture_dir}/pacman/sync/core.db" ]] \
    || fail 'optional repository cleanup removed an authoritative database'

printf '%s\n' bootc >"${fixture_dir}/initramfs-modules"
printf '%s\n' \
    usr/lib/bootc/initramfs-setup \
    usr/lib/systemd/system/bootc-root-setup.service \
    >"${fixture_dir}/initramfs-contents"
if verify_bootc_initramfs_reports \
    "${fixture_dir}/initramfs-modules" \
    "${fixture_dir}/initramfs-contents"; then
    fail 'initramfs verifier accepted a report without the required OSTree module'
fi

printf '%s\n' ostree bootc >"${fixture_dir}/initramfs-modules"
printf '%s\n' \
    usr/lib/ostree/ostree-prepare-root \
    usr/lib/systemd/system/ostree-prepare-root.service \
    usr/lib/bootc/initramfs-setup \
    usr/lib/systemd/system/bootc-root-setup.service \
    >"${fixture_dir}/initramfs-contents"
verify_bootc_initramfs_reports \
    "${fixture_dir}/initramfs-modules" \
    "${fixture_dir}/initramfs-contents" \
    || fail 'initramfs verifier rejected the required bootc v1.16.13 payload'

adoption_fixture="${fixture_dir}/adoption-empty"
mkdir -p "${adoption_fixture}/var/home"
OMARCHY_ADOPTION_HOME_ROOT="${adoption_fixture}/var/home" \
    OMARCHY_ADOPTION_STATE_ROOT="${adoption_fixture}/var/lib/omarchy-bootc/adoption" \
    OMARCHY_INSTALLER_ORIGIN_FILE="${adoption_fixture}/var/lib/omarchy-bootc/installer-origin" \
    OMARCHY_ADOPTION_USER_FILE="${adoption_fixture}/etc/omarchy/adoption-user" \
    bash "${ADOPTION_SCRIPT}"
grep -Fq 'status=no-existing-user' \
    "${adoption_fixture}/var/lib/omarchy-bootc/adoption/state.env" \
    || fail 'empty fresh boot incorrectly entered user adoption'

test_uid="$(id -u)"
test_gid="$(id -g)"
if (( test_uid >= 1000 )); then
    multi_fixture="${fixture_dir}/adoption-multiple"
    mkdir -p "${multi_fixture}/var/home/alice" "${multi_fixture}/var/home/bob"
    chown "${test_uid}:${test_gid}" \
        "${multi_fixture}/var/home/alice" "${multi_fixture}/var/home/bob"
    if OMARCHY_ADOPTION_HOME_ROOT="${multi_fixture}/var/home" \
        OMARCHY_ADOPTION_STATE_ROOT="${multi_fixture}/var/lib/omarchy-bootc/adoption" \
        OMARCHY_INSTALLER_ORIGIN_FILE="${multi_fixture}/var/lib/omarchy-bootc/installer-origin" \
        OMARCHY_ADOPTION_USER_FILE="${multi_fixture}/etc/omarchy/adoption-user" \
        bash "${ADOPTION_SCRIPT}"; then
        fail 'adoption silently selected one of multiple existing homes'
    fi
    grep -Fq 'status=needs-selection' \
        "${multi_fixture}/var/lib/omarchy-bootc/adoption/state.env" \
        || fail 'multiple existing homes did not enter bounded selection'
fi

printf 'PASS: Quattro source and boot ownership contract\n'
