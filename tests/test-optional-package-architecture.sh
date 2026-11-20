#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/build/lib/quattro-packages.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
package=asus-proart-p14-speaker-firmware
pacman() { printf '%s\n' "${resolution_error:-error: target not found: $package}" >&2; return 1; }
pacman-conf() { printf '%s\n' "$architecture"; }
architecture=x86_64
resolve_quattro_optional_package config "$package" "$fixture/report" "$ROOT_DIR/sources" "$fixture/work"
grep -q '^not-applicable-architecture asus-proart-p14-speaker-firmware ' "$fixture/report"
if grep -q '^resolvable' "$fixture/report"; then
    echo 'FAIL: architecture exclusion claimed package resolution' >&2
    exit 1
fi
printf 'resolvable base\n' >>"$fixture/report"
verify_optional_resolution_report "$fixture/report"
architecture=aarch64
resolve_quattro_optional_package config "$package" "$fixture/arm-report" "$ROOT_DIR/sources" "$fixture/work"
grep -q '^unresolved ' "$fixture/arm-report"
if verify_optional_resolution_report "$fixture/arm-report" 2>/dev/null; then
    echo 'FAIL: missing native architecture package was accepted' >&2
    exit 1
fi
architecture=x86_64
package=unrelated-missing-package
resolve_quattro_optional_package config "$package" "$fixture/other-report" "$ROOT_DIR/sources" "$fixture/work"
grep -q '^unresolved ' "$fixture/other-report"
package=asus-proart-p14-speaker-firmware
resolution_error='error: failed to synchronize all databases'
resolve_quattro_optional_package config "$package" "$fixture/network-report" "$ROOT_DIR/sources" "$fixture/work"
grep -q '^unresolved ' "$fixture/network-report"
printf 'PASS: ARM-only hardware is explicitly inapplicable on x86_64; native and unrelated failures remain fatal\n'
