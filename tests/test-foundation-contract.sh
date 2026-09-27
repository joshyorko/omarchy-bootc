#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
containerfile="${root_dir}/Containerfile"
contract="${root_dir}/build/foundation-contract.sh"
hypothesis="${root_dir}/docs/foundation-hypothesis.md"

grep -Fq 'ARG BOOTC_VERSION="v1.16.13"' "${containerfile}"
grep -Fq 'ARG BOOTC_REVISION="fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60"' "${containerfile}"
grep -Fq 'ARG BOOTCREW_MONO_REVISION="5f048fa65a94daefc814d3cdd941d8d1e113c09e"' "${containerfile}"
grep -Fq 'ARG ARCH_BOOTSTRAP_REF="docker.io/archlinux/archlinux:latest@sha256:0de35fe2ee793494ccfc99b202f6b30215b078baf2b082e9ccb027840c534fc1"' "${containerfile}"
grep -Fq 'ARG SELINUX_USERSPACE_VERSION="3.11"' "${containerfile}"
grep -Fq 'ARG COREUTILS_VERSION="9.11"' "${containerfile}"
grep -Fq 'COREUTILS_SOURCE_URL="https://github.com/coreutils/coreutils/releases/download/v9.11/coreutils-9.11.tar.xz"' "${containerfile}"
grep -Fq 'FROM bootcrew-system AS foundation' "${containerfile}"
grep -Fq 'FROM bootcrew-system AS quattro-assembly' "${containerfile}"
grep -Fq 'FROM quattro-base AS quattro-integration' "${containerfile}"
grep -Fq 'bootc container lint --fatal-warnings' "${containerfile}"
grep -Fq -- '--with-selinux' "${containerfile}"
grep -Fq '/usr/bin/chcon' "${containerfile}"
grep -Fq 'build/foundation-contract.sh' "${containerfile}"
grep -Fq 'add_dracutmodules+=" ostree bootc "' "${root_dir}/vendor/bootcrew/shared/initramfs.sh"
grep -Fq 'runtime contract' "${hypothesis}"
grep -Fq 'oci-native/archlinux' "${hypothesis}"
grep -Fq 'coreutils-selinux' "${hypothesis}"
grep -Fq 'smallest adaptation' "${hypothesis}"
test -s "${contract}"
grep -Fq 'bootc container lint --fatal-warnings' "${contract}"
grep -Fq 'mkcomposefs' "${contract}"
grep -Fq '/usr/lib/dracut/modules.d/51bootc' "${contract}"
grep -Fq '/usr/lib/ostree/prepare-root.conf' "${contract}"

foundation_block="$(sed -n '/^FROM bootcrew-system AS foundation$/,/^FROM /p' "${containerfile}")"
test -n "${foundation_block}"
! grep -Fq '20-quattro.sh' <<<"${foundation_block}"
! grep -Fq 'omarchy' <<<"${foundation_block}" || grep -Fq 'omarchy-bootc' <<<"${foundation_block}"

printf 'foundation source contract passed\n'
