#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${ROOT_DIR}/scripts/ci/candidate-runtime.sh"
SMOKE="${ROOT_DIR}/scripts/ci/vm-smoke.sh"
HELPER="${ROOT_DIR}/scripts/ci/lib/upstream-acceptance.sh"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[[ -x "${RUNTIME}" ]] || fail 'candidate runtime runner is missing or not executable'
[[ -x "${SMOKE}" ]] || fail 'VM smoke runner is missing or not executable'
[[ -x "${HELPER}" ]] || fail 'upstream acceptance helper is missing or not executable'
# Exercise the changed Arch header-target boundary, including rejection of an
# unrelated resolved header path.
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/ci/guest-bootc-acceptance.sh"
modules='/usr/lib/modules/6.12.1-arch1-1'
bootc_kernel_headers_path_allowed \
    '/usr/src/linux-headers-6.12.1-arch1-1/include/config/kernel.release' \
    "${modules}" ||
    fail 'Arch /usr/src kernel headers were rejected'
bootc_kernel_headers_path_allowed \
    "${modules}/build/include/config/kernel.release" \
    "${modules}" ||
    fail 'in-tree kernel headers were rejected'
if bootc_kernel_headers_path_allowed '/usr/src/linux-headers-unrelated/include/config/kernel.release' "${modules}"; then
    fail 'unrelated /usr/src kernel headers were accepted'
fi
if bootc_kernel_headers_path_allowed '/tmp/kernel.release' "${modules}"; then
    fail 'unrelated kernel headers were accepted'
fi


assert_order() {
    local file="$1" label="$2" previous=0 needle line
    shift 2
    for needle in "$@"; do
        line="$(grep -nF "$needle" "${file}" | head -n1 | cut -d: -f1)" ||
            fail "${label} is missing: ${needle}"
        (( line >= previous )) || fail "${label} is out of order at: ${needle}"
        previous="${line}"
    done
}

# The runtime runner must execute the exact adapted tree it fetched and pass
# that tree into the VM harness; a receipt-only adapter test is insufficient.
# These assertions preserve the exact remote/guest command strings.
# shellcheck disable=SC2016
assert_order "${RUNTIME}" 'candidate runtime acceptance handoff' \
    'git -C "${upstream_tests}" archive FETCH_HEAD test/acceptance test/acceptance.d' \
    'python3 scripts/ci/adapt-upstream-acceptance.py' \
    '"UPSTREAM_ACCEPTANCE_DIR=${upstream_tests}"' \
    'bash scripts/ci/vm-smoke.sh "${overlay}"'
# This contract needle is literal shell syntax.
# shellcheck disable=SC2016
grep -Fq '"CI_ARTIFACT_DIR=${artifact_dir}"' "${RUNTIME}" ||
    fail 'candidate runtime does not pass its receipt directory to VM smoke'
# This contract needle is literal shell syntax.
# shellcheck disable=SC2016
grep -Fq '"UPSTREAM_ACCEPTANCE_DIR=${upstream_tests}"' "${RUNTIME}" ||
    fail 'candidate runtime does not pass the adapted suite to VM smoke'

# The helper must transfer the adapted tests, execute the real acceptance
# entrypoint, retain output, and return failure to the VM harness.
# These commands are literal remote command text.
# shellcheck disable=SC2016
assert_order "${HELPER}" 'upstream acceptance execution' \
    '"${upstream_dir}/test"' \
    'mkdir -p "$HOME/upstream-acceptance/test"' \
    'cp -a "$HOME/upstream-acceptance-test/." "$HOME/upstream-acceptance/test/"' \
    'bash "$HOME/upstream-acceptance/test/acceptance"' \
    'acceptance_status=1' \
    'return "${acceptance_status}"'
assert_order "${SMOKE}" 'upstream acceptance handoff' \
    'run_upstream_acceptance' \
    'acceptance_status=1'
grep -Fq 'upstream-acceptance.log' "${HELPER}" ||
    fail 'upstream acceptance helper does not retain output'


fixture="$(mktemp -d)"
trap 'rm -rf -- "${fixture}"' EXIT
mkdir -p "${fixture}/upstream/test" "${fixture}/bin" "${fixture}/artifacts"
printf '#!/usr/bin/env bash\nexit 0\n' >"${fixture}/upstream/test/acceptance"
cat >"${fixture}/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${FAKE_SCP_ARGS}"
exit "${FAKE_SCP_STATUS:-0}"
EOF
chmod 0755 "${fixture}/bin/sshpass"
export FAKE_SCP_ARGS="${fixture}/scp.args"
export PATH="${fixture}/bin:${PATH}"
# shellcheck disable=SC1090
source "${HELPER}"
run_guest() {
    if [[ "$*" == *'timeout 20m bash'* ]]; then
        printf 'acceptance fixture status %s\n' "${FAKE_ACCEPTANCE_STATUS}"
        return "${FAKE_ACCEPTANCE_STATUS}"
    fi
    return 0
}
FAKE_ACCEPTANCE_STATUS=0
run_upstream_acceptance \
    "${fixture}/upstream" "${fixture}/artifacts" omarchy 2222 omarchy ||
    fail 'acceptance helper rejected a passing fixture'
grep -Fq -- '-r -P 2222' "${fixture}/scp.args" ||
    fail 'acceptance helper did not transfer the test tree recursively'
export FAKE_SCP_STATUS=7
if run_upstream_acceptance \
    "${fixture}/upstream" "${fixture}/artifacts" omarchy 2222 omarchy; then
    fail 'acceptance helper swallowed a transfer failure'
fi
export FAKE_SCP_STATUS=0
FAKE_ACCEPTANCE_STATUS=7
if run_upstream_acceptance \
    "${fixture}/upstream" "${fixture}/artifacts" omarchy 2222 omarchy; then
    fail 'acceptance helper swallowed a failing acceptance fixture'
fi
grep -Fq 'acceptance fixture status 7' "${fixture}/artifacts/upstream-acceptance.log" ||
    fail 'acceptance helper did not retain the failing output'

grep -Fq 'docker.io/library/registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373' \
    "${SMOKE}" || fail 'lifecycle registry fixture is not digest-pinned'
if grep -Fq 'docker.io/library/registry:2.8.3' "${SMOKE}"; then
    fail 'lifecycle registry fixture still uses a mutable tag'
fi

printf 'runtime acceptance wiring contract passed\n'
