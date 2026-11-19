#!/usr/bin/env bash
set -euo pipefail

# Product image inputs must match; the disposable overlay is rebuilt and linted.
# The dependency verifier is explicitly refreshed by that overlay as test code.
source_head="${1:?Expected full candidate source SHA}"
harness_head="${2:-HEAD}"
[[ "${source_head}" =~ ^[[:xdigit:]]{40}$ ]] || {
    echo 'Candidate source must be a full commit SHA' >&2
    exit 1
}
git cat-file -e "${source_head}^{commit}"
if ! git diff --quiet "${source_head}" "${harness_head}" -- . \
    ':!.github/workflows/candidate.yml' \
    ':!.github/workflows/build.yml' \
    ':!.github/workflows/dagger-parity.yml' \
    ':!.dagger/candidate.go' \
    ':!scripts/ci/dagger-candidate.sh' \
    ':!scripts/ci/dagger-engine.sh' \
    ':!scripts/ci/dagger-host-runtime.sh' \
    ':!scripts/ci/devsy-dagger.sh' \
    ':!scripts/ci/devsy-dagger-worker.sh' \
    ':!scripts/ci/prepare-ubuntu-runner.sh' \
    ':!.devcontainer/acceptance' \
    ':!scripts/ci/harvester-cache-proof.sh' \
    ':!scripts/ci/candidate-runtime.sh' \
    ':!scripts/ci/adapt-upstream-acceptance.py' \
    ':!scripts/ci/vm-smoke.sh' \
    ':!scripts/ci/guest-bootc-acceptance.sh' \
    ':!scripts/ci/guest-native-acceptance.sh' \
    ':!scripts/ci/acceptance-overlay.Containerfile' \
    ':!scripts/ci/verify-candidate-reuse.sh' \
    ':!build/acceptance-dependencies.sh' \
    ':!build/acceptance-firstboot.sh' \
    ':!scripts/ci/lib/upstream-acceptance.sh' \
    ':!tests/test-acceptance-dependencies.sh' \
    ':!tests/test-acceptance-overlay.sh' \
    ':!tests/test-sddm-capture.sh' \
    ':!tests/test-upstream-acceptance-adapter.sh' \
    ':!tests/test-runtime-acceptance-contract.sh' \
    ':!tests/test-candidate-reuse.sh'; then
    echo 'Candidate reuse rejected: image or unchecked harness inputs differ' >&2
    exit 1
fi
printf 'Candidate source %s matches image inputs at harness %s\n' \
    "${source_head}" "$(git rev-parse "${harness_head}")"
