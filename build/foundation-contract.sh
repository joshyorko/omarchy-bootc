#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'foundation contract failed: %s\n' "$@" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

require_elf() {
    local path="$1"
    [[ -x "$path" ]] || fail "missing executable: $path"
    if ldd "$path" 2>&1 | grep -q 'not found'; then
        fail "unresolved runtime library for $path"
    fi
}

for command in bootc chcon ostree podman skopeo zstd setpriv systemctl pacman dracut systemd-sysusers mkcomposefs; do
    require_command "$command"
done

for path in \
    /usr/bin/bootc \
    /usr/bin/chcon \
    /usr/bin/ostree \
    /usr/bin/podman \
    /usr/bin/skopeo \
    /usr/bin/zstd \
    /usr/bin/setpriv \
    /usr/bin/systemctl \
    /usr/bin/mkcomposefs \
    /usr/lib/bootc/initramfs-setup; do
    require_elf "$path"
done

bootc_version="$(bootc --version 2>&1)"
grep -Eq '(^|[[:space:]])1\.16\.13([[:space:]]|$)' <<<"${bootc_version}" \
    || fail "unexpected bootc version: ${bootc_version}"

[[ -r /usr/share/omarchy-bootc/sources/bootcrew-mono.revision ]] \
    || fail "Bootcrew source receipt missing" \
[[ "$(tr -d '\r\n' < /usr/share/omarchy-bootc/sources/bootcrew-mono.revision)" \
    == "5f048fa65a94daefc814d3cdd941d8d1e113c09e" ]] \
    || fail "Bootcrew source revision receipt mismatch" \
[[ -r /usr/share/omarchy-bootc/sources/bootc.revision ]] \
    || fail "bootc source receipt missing"
[[ -r /usr/share/omarchy-bootc/sources/bootcrew-mono.revision ]] \
    || fail "Bootcrew source receipt missing"
[[ "$(tr -d '\r\n' < /usr/share/omarchy-bootc/sources/bootcrew-mono.revision)" \
    == "5f048fa65a94daefc814d3cdd941d8d1e113c09e" ]] \
    || fail "Bootcrew source revision receipt mismatch"
[[ "$(tr -d '\r\n' < /usr/share/omarchy-bootc/sources/bootc.revision)" \
    == "fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60" ]] \
    || fail "bootc source revision receipt is not v1.16.13"
[[ -r /usr/share/omarchy-bootc/sources/bootc-version ]] \
    || fail "bootc version receipt missing"
[[ "$(tr -d '\r\n' < /usr/share/omarchy-bootc/sources/bootc-version)" == "v1.16.13" ]] \
    || fail "bootc version receipt mismatch"

pacman -Q composefs >/dev/null 2>&1 \
    || fail "composefs package is not installed"
[[ -d /sysroot ]] || fail "missing /sysroot logical root"
[[ -L /ostree ]] || fail "/ostree is not a symlink"
[[ "$(readlink /ostree)" == *ostree* ]] || fail "/ostree does not target ostree state"
[[ -r /usr/lib/libselinux.so.1 ]] || fail "libselinux runtime library is missing"
[[ -r /usr/lib/libsepol.so.2 ]] || fail "libsepol runtime library is missing"
[[ -x /usr/lib/bootc/initramfs-setup ]] || fail "bootc initramfs setup is not executable"
[[ -d /usr/lib/dracut/modules.d/51bootc ]] \
    || fail "bootc dracut module is missing"
find /usr/lib/dracut/modules.d -mindepth 1 -maxdepth 1 -type d \
    -iname '*ostree*' -print -quit | grep -q . \
    || fail "ostree dracut module is missing"
grep -R -Eq 'ostree|bootc' /usr/lib/dracut/modules.d/51bootc \
    || fail "bootc dracut module has no ostree/bootc integration" \
[[ -r /usr/lib/dracut/dracut.conf.d/31-omarchy-bootc-native.conf ]] \
    || fail "native dracut configuration is missing" \
grep -Eq 'ostree bootc' /usr/lib/dracut/dracut.conf.d/31-omarchy-bootc-native.conf \
    || fail "native dracut configuration does not request ostree and bootc"
grep -R -Eq 'add_dracutmodules.*(ostree.*bootc|bootc.*ostree)' \
    /usr/lib/dracut/dracut.conf.d \
    || fail "dracut configuration does not request ostree and bootc"
[[ -r /usr/lib/ostree/prepare-root.conf ]] \
    || fail "native-composefs prepare-root configuration is missing"
grep -Eq '^\[composefs\]' /usr/lib/ostree/prepare-root.conf \
    || fail "prepare-root configuration has no composefs section"
grep -Eq '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*(yes|true)' \
    /usr/lib/ostree/prepare-root.conf \
    || fail "composefs is not enabled"

bootc container lint --fatal-warnings

receipt=/usr/share/omarchy-bootc/foundation-receipt.txt
install -d -m 0755 "$(dirname "$receipt")"
{
    printf 'schema=omarchy-bootc.foundation/v1\n'
    printf 'bootc_version=v1.16.13\n'
    printf 'bootc_revision=fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60\n'
    printf 'native_composefs=enabled\n'
    printf 'runtime_contract=passed\n'
    printf 'fatal_lint=passed\n'
} >"${receipt}"
printf 'bootc foundation contract passed: %s\n' "${receipt}"
