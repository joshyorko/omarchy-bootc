#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINERFILE="${ROOT_DIR}/Containerfile"
QUATTRO_BUILD="${ROOT_DIR}/build/20-quattro.sh"
BOOT_OWNERSHIP="${ROOT_DIR}/build/30-bootc-ownership.sh"
PACKAGE_HELPERS="${ROOT_DIR}/build/lib/quattro-packages.sh"
PAYLOAD_VERIFIER="${ROOT_DIR}/build/verify-quattro-payload.sh"
REPOSITORY_CONFIG="${ROOT_DIR}/custom/pacman/quattro-repositories.conf"
HOOK_INVENTORY="${ROOT_DIR}/build/bootc-disabled-hooks.txt"
FINAL_IMAGE_VERIFIER="${ROOT_DIR}/build/verify-publishable-image.sh"
ACCEPTANCE_NODE_STAGER="${ROOT_DIR}/build/stage-acceptance-node.sh"
ACCEPTANCE_FIRSTBOOT="${ROOT_DIR}/build/acceptance-firstboot.sh"
BOOTCREW_REVISION_FILE="${ROOT_DIR}/vendor/bootcrew/REVISION"
BOOTC_REVISION_FILE="${ROOT_DIR}/vendor/bootcrew/BOOTC_REVISION"
BOOTCREW_SOURCE_FILE="${ROOT_DIR}/vendor/bootcrew/SOURCE"
BOOTC_SOURCE_FILE="${ROOT_DIR}/vendor/bootcrew/BOOTC_SOURCE"
BOOTCREW_CHECKSUMS="${ROOT_DIR}/vendor/bootcrew/SHA256SUMS"
REPOSITORY_CONFIGURATOR="${ROOT_DIR}/build/configure-quattro-repositories.sh"
DESIGN_CONTRACT="${ROOT_DIR}/docs/superpowers/specs/2026-08-26-omarchy-quattro-bootc-design.md"
INSTALLER_CONTRACT="${ROOT_DIR}/docs/installer-parity-contract.md"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

if grep -Eqi '^[[:space:]]*FROM[[:space:]].*(ghcr\.io/)?bootcrew/' "${CONTAINERFILE}"; then
    fail 'published Bootcrew package payload must not seed the final image'
fi
grep -Fq 'ARG BOOTCREW_MONO_REVISION="5f048fa65a94daefc814d3cdd941d8d1e113c09e"' \
    "${CONTAINERFILE}" || fail 'Containerfile does not pin the reviewed Bootcrew mono revision'
grep -Fq 'ARG BOOTC_REVISION="3e76c16556c55e6d15d31bd47602b231e2131cb2"' \
    "${CONTAINERFILE}" || fail 'Containerfile does not pin the reviewed bootc revision'
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
[[ -f "${BOOTC_REVISION_FILE}" ]] || fail 'pinned bootc source revision is missing'
[[ "$(<"${BOOTC_REVISION_FILE}")" == '3e76c16556c55e6d15d31bd47602b231e2131cb2' ]] \
    || fail 'bootc source revision differs from v1.16.10'
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

[[ -f "${QUATTRO_BUILD}" ]] || fail 'build/20-quattro.sh is missing'
[[ -f "${BOOT_OWNERSHIP}" ]] || fail 'build/30-bootc-ownership.sh is missing'

grep -Fq 'OMARCHY_VERSION="4.0.1-1"' "${QUATTRO_BUILD}" \
    || fail 'official Omarchy package version is not pinned to 4.0.1-1'
grep -Fq '/usr/share/omarchy/install/omarchy-base.packages' "${QUATTRO_BUILD}" \
    || fail 'Quattro base package manifest is not consumed from the official package'
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
    "${ROOT_DIR}/custom" "${ROOT_DIR}/build"; then
    fail 'local replacement for an upstream omarchy command exists'
fi

[[ -f "${PACKAGE_HELPERS}" ]] || fail 'Quattro package manifest helper is missing'
[[ -f "${PAYLOAD_VERIFIER}" ]] || fail 'Quattro package provenance verifier is missing'
[[ -f "${REPOSITORY_CONFIG}" ]] || fail 'official Quattro repository topology is missing'
[[ -f "${HOOK_INVENTORY}" ]] || fail 'disabled-hook evidence inventory is missing'
[[ -f "${FINAL_IMAGE_VERIFIER}" ]] || fail 'publishable-image credential verifier is missing'
[[ -f "${ACCEPTANCE_NODE_STAGER}" ]] || fail 'official ISO Node staging input is missing from acceptance'
[[ -f "${ACCEPTANCE_FIRSTBOOT}" ]] || fail 'acceptance first-boot finalization is missing'

grep -Fq 'FROM quattro-base AS acceptance' "${CONTAINERFILE}" \
    || fail 'acceptance identity is not isolated in its own image target'
grep -Fq 'FROM quattro-base AS final' "${CONTAINERFILE}" \
    || fail 'publishable final image is not separated from acceptance identity'
grep -Fq 'omarchy-provision-user --first-install' "${ACCEPTANCE_FIRSTBOOT}" \
    || fail 'acceptance user does not run official Quattro finalization'
grep -Fq '.local/state/omarchy/done/finalize-user' "${ACCEPTANCE_FIRSTBOOT}" \
    || fail 'acceptance user finalization marker is not proved'

[[ -f "${INSTALLER_CONTRACT}" ]] || fail 'official Omarchy installer parity contract is missing'
grep -Fq '268bac16d351a21d867e37565738f458b11cb06c' "${INSTALLER_CONTRACT}" \
    || fail 'official Omarchy Quattro ISO source revision is not pinned'
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

for required_validation_input in \
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
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
Include = /etc/pacman.d/mirrorlist

[extra]
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
Include = /etc/pacman.d/mirrorlist

[multilib]
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
Include = /etc/pacman.d/mirrorlist

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch'
[[ "$(<"${REPOSITORY_CONFIG}")" == "${expected_repository_config}" ]] \
    || fail 'Quattro repository topology differs from pacman-online-stable.conf'

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

printf 'PASS: Quattro source and boot ownership contract\n'
