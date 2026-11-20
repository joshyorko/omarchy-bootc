#!/usr/bin/env bash
# Called only at the two adapted upstream assertions. This is not a desktop-test runner.
# Pinned bootc fa0d3f9c crates/initramfs/src/lib.rs mounts the root and sysroot clone
# readonly. Its composefs-rs f720d6c7 crates/composefs/src/mount.rs creates overlay
# source composefs:<SHA-512 hex>, metacopy=on, redirect_dir=on, without an upperdir.

bootc_acceptance_fail() { printf 'not ok - bootc acceptance: %s\n' "$*" >&2; return 1; }

# Pure parser, also exercised with negative fixtures. Runtime callers supply only
# directly captured findmnt / bootc output; no fixture or status-file overrides.
bootc_validate_root() {
    local root_json="$1" backing_json="$2" status_json="$3"
    jq -e -s '
      def opts: .options | split(",");
      def readonly: (opts | index("ro") != null and index("rw") == null);
      .[0].filesystems as $roots | .[1].filesystems as $backings |
      .[2].status.booted as $booted |
      ($roots | length) == 1 and ($backings | length) == 1 and
      ($booted | type) == "object" and
      ($booted.composefs | type) == "object" and $booted.ostree == null and
      ($booted.composefs.verity | type) == "string" and
      ($booted.composefs.verity | test("^[0-9a-f]{128}$")) and
      ($booted.image.imageDigest | test("^sha256:[0-9a-f]{64}$")) and
      ($roots[0] | .target == "/" and .fstype == "overlay" and readonly and
        .source == ("composefs:" + $booted.composefs.verity) and
        (opts | index("metacopy=on") != null and index("redirect_dir=on") != null) and
        (opts | all(.[]; (startswith("upperdir=") or startswith("workdir=")) | not))) and
      ($backings[0] | .target == "/sysroot" and .fstype == "btrfs" and readonly)
    ' "$root_json" "$backing_json" "$status_json" >/dev/null
}

bootc_verify_root() {
    local artifacts="$1"
    findmnt --json --mountpoint / --output TARGET,SOURCE,FSTYPE,OPTIONS >"$artifacts/bootc-native-root.json" || return 1
    findmnt --json --mountpoint /sysroot --output TARGET,SOURCE,FSTYPE,OPTIONS >"$artifacts/bootc-native-sysroot.json" || return 1
    # The SSH user owns the receipt directory; sudo only elevates bootc.
    # shellcheck disable=SC2024
    sudo -n bootc status --format=json --format-version=1 >"$artifacts/bootc-native-status.json" || return 1
    bootc_validate_root "$artifacts/bootc-native-root.json" "$artifacts/bootc-native-sysroot.json" \
        "$artifacts/bootc-native-status.json" ||
        { bootc_acceptance_fail 'root must be readonly composefs matching booted identity, backed by readonly Btrfs /sysroot'; return 1; }
    printf 'ok - immutable composefs root matches booted identity on Btrfs backing\n'
}

bootc_kernel_headers_path_allowed() {
    local headers="$1" modules="$2" component
    [[ "$headers" == "$modules/"* ]] && return 0
    case "$headers" in
        /usr/src/linux-headers-*/include/config/kernel.release)
            component="${headers#/usr/src/}"
            component="${component%%/*}"
            [[ "$component" =~ ^linux-headers-[0-9][A-Za-z0-9+_.-]*$ ]] &&
                [[ "$headers" == "/usr/src/$component/include/config/kernel.release" ]]
            ;;
        *) return 1 ;;
    esac
}

bootc_verify_kernel() {
    local artifacts="$1" kernel release modules headers kernel_version headers_version path mount_json
    # Re-prove root identity here: system-test.sh can run independently of session-test.sh.
    bootc_verify_root "$artifacts" || return 1
    kernel=$(cat /usr/share/omarchy-bootc/kernel-package) || return 1
    [[ $kernel =~ ^[a-z0-9][a-z0-9+_.-]*$ ]] ||
        { bootc_acceptance_fail 'invalid image kernel declaration'; return 1; }
    release=$(uname -r) || return 1
    [[ $release =~ ^[a-zA-Z0-9][a-zA-Z0-9+_.-]*$ ]] || return 1
    modules="/usr/lib/modules/$release"
    headers=$(readlink -e "$modules/build/include/config/kernel.release") || return 1
    # Arch headers normally expose build -> /usr/src/...; accept that
    # package-owned immutable target as well as an in-tree target.
    bootc_kernel_headers_path_allowed "$headers" "$modules" ||
        { bootc_acceptance_fail 'headers resolve outside the image kernel/header trees'; return 1; }
    # Neither a mutable declaration nor bind-mounted replacement kernel/headers
    # may stand in for the immutable image-owned files being accepted.
    for path in /usr/share/omarchy-bootc/kernel-package "$modules/pkgbase" "$modules/vmlinuz" "$headers"; do
        mount_json=$(findmnt --json --target "$path" --output TARGET,SOURCE,FSTYPE,OPTIONS) || return 1
        jq -e --slurpfile root "$artifacts/bootc-native-root.json" \
            '.filesystems == $root[0].filesystems' <<<"$mount_json" >/dev/null ||
            { bootc_acceptance_fail "kernel input is not on the immutable root: $path"; return 1; }
    done
    [[ $(cat "$modules/pkgbase") == "$kernel" ]] ||
        { bootc_acceptance_fail "running kernel pkgbase differs from image declaration $kernel"; return 1; }
    kernel_version=$(pacman -Q "$kernel") || return 1
    headers_version=$(pacman -Q "$kernel-headers") || return 1
    [[ ${kernel_version#"$kernel "} == "${headers_version#"$kernel-headers "}" ]] ||
        { bootc_acceptance_fail 'kernel and headers package versions differ'; return 1; }
    for path in "$modules/pkgbase" "$modules/vmlinuz"; do
        [[ $(pacman -Qqo -- "$path") == "$kernel" ]] ||
            { bootc_acceptance_fail "kernel package does not own $path"; return 1; }
    done
    [[ $(pacman -Qqo -- "$headers") == "$kernel-headers" ]] ||
        { bootc_acceptance_fail 'headers package does not own kernel.release'; return 1; }
    [[ $(cat "$headers") == "$release" ]] ||
        { bootc_acceptance_fail 'headers do not match the running release'; return 1; }
    jq -n --arg kernel "$kernel" --arg release "$release" \
        --arg package "$kernel_version" --arg headers_package "$headers_version" --arg headers "$headers" \
        '{status:"passed",kernel:$kernel,release:$release,package:$package,
          headers_package:$headers_package,headers_release_file:$headers}' >"$artifacts/bootc-native-kernel.json" || return 1
    printf 'ok - running image-declared %s kernel has package-owned matching headers (%s)\n' "$kernel" "$release"
}

bootc_acceptance_main() {
    local mode="${1:-}" artifacts="${OMARCHY_ACCEPTANCE_DIR:?Set OMARCHY_ACCEPTANCE_DIR}"
    mkdir -p "$artifacts" || return 1
    case "$mode" in
        root) bootc_verify_root "$artifacts" ;;
        kernel) bootc_verify_kernel "$artifacts" ;;
        *) bootc_acceptance_fail 'usage: bootc-acceptance-helper.sh <root|kernel>' ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    bootc_acceptance_main "$@"
fi
