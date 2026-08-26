#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSITION="${ROOT_DIR}/transition/omarchy-transition.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[[ -x "${TRANSITION}" ]] || fail 'transition adapter is missing or not executable'
for surface in \
    preflight capture-state backup apply recover bluefin dakota omarchy \
    'bootc switch' '/var/lib/omarchy-bootc/transitions' adoption-rollback --confirm; do
    grep -Fq -- "${surface}" "${TRANSITION}" \
        || fail "transition adapter is missing ${surface}"
done
grep -Fq 'refusing to switch before state capture' "${TRANSITION}" \
    || fail 'transition adapter does not gate switching on captured state'
grep -Fqi 'password hashes' "${TRANSITION}" \
    || fail 'transition capture does not declare credential exclusion'

fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT
mkdir -p "${fixture_dir}/usr/lib" "${fixture_dir}/usr/bin" \
    "${fixture_dir}/etc" "${fixture_dir}/var/home/alice"
cat >"${fixture_dir}/usr/lib/os-release" <<'EOF'
ID=dakota
NAME="Dakota"
EOF
printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' \
    'alice:$6$secret:1000:1000:Alice:/var/home/alice:/bin/bash' \
    >"${fixture_dir}/etc/passwd"
printf '%s\n' 'root:x:0:' 'alice:x:1000:' >"${fixture_dir}/etc/group"
touch "${fixture_dir}/usr/bin/bootc"
chmod +x "${fixture_dir}/usr/bin/bootc"

preflight_output="$(
    OMARCHY_TRANSITION_ROOT="${fixture_dir}" \
        OMARCHY_TRANSITION_STATE_ROOT="${fixture_dir}/var/lib/omarchy-bootc/transitions" \
        bash "${TRANSITION}" preflight \
        ghcr.io/joshyorko/omarchy-bootc@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
)"
grep -Fq 'source_profile=dakota' <<<"${preflight_output}" \
    || fail 'Dakota preflight did not identify the source profile'
grep -Fq 'status=ready' <<<"${preflight_output}" \
    || fail 'preflight did not report ready'

sed -i -e 's/^ID=.*/ID=unknown/' -e 's/^NAME=.*/NAME="Unknown"/' \
    "${fixture_dir}/usr/lib/os-release"
if OMARCHY_TRANSITION_ROOT="${fixture_dir}" \
    OMARCHY_TRANSITION_STATE_ROOT="${fixture_dir}/var/lib/omarchy-bootc/transitions" \
    bash "${TRANSITION}" preflight \
    ghcr.io/joshyorko/omarchy-bootc:quattro; then
    fail 'unknown source profile was accepted'
fi
sed -i -e 's/^ID=.*/ID=dakota/' -e 's/^NAME=.*/NAME="Dakota"/' \
    "${fixture_dir}/usr/lib/os-release"

capture_output="$(
    OMARCHY_TRANSITION_ROOT="${fixture_dir}" \
        OMARCHY_TRANSITION_STATE_ROOT="${fixture_dir}/var/lib/omarchy-bootc/transitions" \
        bash "${TRANSITION}" capture-state
)"
grep -Fq 'captured' <<<"${capture_output}" \
    || fail 'capture-state did not report captured state'
if rg -q '\$6\$secret' "${fixture_dir}/var/lib/omarchy-bootc/transitions"; then
    fail 'transition capture copied a password hash'
fi

printf 'PASS: cross-distro transition contract\n'
