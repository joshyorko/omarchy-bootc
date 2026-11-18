#!/usr/bin/env bash
set -euo pipefail

# Reuse is allowed only when the image and disposable overlay inputs match.
source_head="${1:?Expected full candidate source SHA}"
harness_head="${2:-HEAD}"
[[ "${source_head}" =~ ^[[:xdigit:]]{40}$ ]] || {
    echo 'Candidate source must be a full commit SHA' >&2
    exit 1
}
git cat-file -e "${source_head}^{commit}"
if ! git diff --quiet "${source_head}" "${harness_head}" -- . \
    ':!.github/workflows/candidate.yml' \
    ':!scripts/ci/candidate-runtime.sh' \
    ':!scripts/ci/verify-candidate-reuse.sh' \
    ':!tests/test-candidate-reuse.sh'; then
    echo 'Candidate reuse rejected: image or unchecked harness inputs differ' >&2
    exit 1
fi
printf 'Candidate source %s matches image inputs at harness %s\n' \
    "${source_head}" "$(git rev-parse "${harness_head}")"
