#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/build/lib/quattro-packages.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/sources" "$fixture/server" "$fixture/payload"
printf '4.0.4-1\n' >"$fixture/sources/omarchy-quattro-version"
make_packages() {
    local package
    : >"$fixture/sources/omarchy-packages.sha256"
    for package in omarchy omarchy-settings; do
        printf 'pkgname = %s\npkgver = %s\narch = x86_64\n' "$package" "${metadata_version:-4.0.4-1}" >"$fixture/payload/.PKGINFO"
        tar -cf "$fixture/server/$package-4.0.4-1-x86_64.pkg.tar.zst" -C "$fixture/payload" .PKGINFO
        printf 'signature\n' >"$fixture/server/$package-4.0.4-1-x86_64.pkg.tar.zst.sig"
        (cd "$fixture/server" && sha256sum "$package-4.0.4-1-x86_64.pkg.tar.zst") >>"$fixture/sources/omarchy-packages.sha256"
    done
}
# Transport and signature-tool doubles; hashes and archive parsing are real.
curl() {
    local url="${*: -3:1}" output="${*: -1}"
    [[ "$url" == https://pkgs.omarchy.org/stable/x86_64/* ]] || return 1
    cp "$fixture/server/${url##*/}" "$output"
}
pacman-key() {
    [[ "$1" == --verify && -f "$2" && -f "$3" && "${bad_signature:-0}" == 0 ]]
}
make_packages
# Latest channel metadata is deliberately irrelevant: these are frozen inputs.
fetch_frozen_quattro_packages "$fixture/sources" "$fixture/download"
for package in omarchy omarchy-settings; do
    cmp "$fixture/server/$package-4.0.4-1-x86_64.pkg.tar.zst" "$fixture/download/$package-4.0.4-1-x86_64.pkg.tar.zst"
done
expect_failure() {
    if fetch_frozen_quattro_packages "$fixture/sources" "$fixture/download" >"$fixture/error" 2>&1; then
        echo 'FAIL: invalid frozen package accepted' >&2
        exit 1
    fi
}
printf 'tampered' >>"$fixture/server/omarchy-4.0.4-1-x86_64.pkg.tar.zst"
expect_failure
make_packages
sed -i '/omarchy-settings/d' "$fixture/sources/omarchy-packages.sha256"
expect_failure
make_packages
bad_signature=1
expect_failure
bad_signature=0
metadata_version=4.5.0-3
make_packages
expect_failure
printf 'PASS: frozen package selection, checksum, signature failure and version boundaries\n'
