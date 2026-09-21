#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSITION="${ROOT_DIR}/transition/omarchy-transition.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$TRANSITION" ]] || fail 'transition adapter is missing or not executable'
for surface in inspect-source preflight capture-state backup apply verify-boot recover \
    bluefin dakota omarchy 'bootc switch' '/var/lib/omarchy-bootc/transitions' \
    target_tracking_ref target_resolved_digest source_evidence --confirm; do
    grep -Fq -- "$surface" "$TRANSITION" || fail "transition adapter is missing ${surface}"
done
grep -Fq 'target digest moved after preflight' "$TRANSITION" || fail 'apply does not refuse target movement'
grep -Fq 'refusing to switch before state capture and backup' "$TRANSITION" || fail 'apply is not gated on backup'
grep -Fqi 'password hashes' "$TRANSITION" && true || grep -Fq 'Identity-only' "$TRANSITION" || fail 'capture contract is not credential-safe'

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/usr/lib" "$fixture_dir/usr/bin" "$fixture_dir/etc" "$fixture_dir/var/home/alice"
cat >"$fixture_dir/usr/lib/os-release" <<'EOF'
ID=bluefin-dakota
NAME="Bluefin"
EOF
printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' \
    "alice:\$6\$secret:1000:1000:Alice:/var/home/alice:/bin/bash" >"$fixture_dir/etc/passwd"
printf '%s\n' 'root:x:0:' 'alice:x:1000:' >"$fixture_dir/etc/group"
cat >"$fixture_dir/usr/bin/bootc" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == status ]]; then
    printf '%s\n' '{"deployments":[{"booted":true,"image":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}'
fi
EOF
chmod +x "$fixture_dir/usr/bin/bootc"
cat >"$fixture_dir/resolve-digest" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
chmod +x "$fixture_dir/resolve-digest"

common_env=(
    OMARCHY_TRANSITION_ROOT="$fixture_dir"
    OMARCHY_TRANSITION_STATE_ROOT="$fixture_dir/var/lib/omarchy-bootc/transitions"
    OMARCHY_TRANSITION_RESOLVER="$fixture_dir/resolve-digest"
)
inspect_output="$(env "${common_env[@]}" bash "$TRANSITION" inspect-source)"
grep -Fq '"profile":"dakota"' <<<"$inspect_output" || fail 'current Project Bluefin Dakota was not classified as Dakota'
grep -Fq '"signal":"os-release"' <<<"$inspect_output" || fail 'source signal was not reported'

preflight_output="$(env "${common_env[@]}" bash "$TRANSITION" preflight ghcr.io/joshyorko/omarchy-bootc:testing)"
grep -Fq 'source_profile=dakota' <<<"$preflight_output" || fail 'Dakota preflight did not identify the source profile'
grep -Fq 'target_tracking_ref=ghcr.io/joshyorko/omarchy-bootc:testing' <<<"$preflight_output" || fail 'tracking ref was not persisted'
grep -Fq 'target_resolved_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' <<<"$preflight_output" || fail 'resolved digest was not persisted'
grep -Fq 'status=ready' <<<"$preflight_output" || fail 'preflight did not report ready'

if env "${common_env[@]}" bash "$TRANSITION" preflight ghcr.io/joshyorko/omarchy-bootc@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then
    fail 'digest-only target was accepted without a tracking ref'
fi

sed -i -e 's/^ID=.*/ID=unknown/' -e 's/^NAME=.*/NAME="Unknown"/' "$fixture_dir/usr/lib/os-release"
if env "${common_env[@]}" bash "$TRANSITION" preflight ghcr.io/joshyorko/omarchy-bootc:testing; then
    fail 'unknown source profile was accepted'
fi
sed -i -e 's/^ID=.*/ID=dakota/' -e 's/^NAME=.*/NAME="Dakota"/' "$fixture_dir/usr/lib/os-release"

env "${common_env[@]}" bash "$TRANSITION" capture-state | grep -Fq 'status=captured' || fail 'capture-state did not report captured state'
if grep -R -q "\$6\$secret" "$fixture_dir/var/lib/omarchy-bootc/transitions"; then
    fail 'transition capture copied a password hash'
fi
env "${common_env[@]}" bash "$TRANSITION" backup | grep -Fq 'status=backed-up' || fail 'backup did not report backed-up state'

cat >"$fixture_dir/status.json" <<'EOF'
{"deployments":[{"booted":true,"image":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}
EOF
env "${common_env[@]}" OMARCHY_TRANSITION_STATUS_FILE="$fixture_dir/status.json" \
    bash "$TRANSITION" verify-boot | grep -Fq 'status=verified' || fail 'post-boot digest verification failed'

printf 'PASS: cross-distro transition contract\n'
