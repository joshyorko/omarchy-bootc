#!/usr/bin/env bash
# Deliberate host-capability boundary, shared by Harvester and GitHub Actions.
# Keep bootc install-to-disk/QEMU here until nested capability equivalence passes.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true || ${OMARCHY_REMOTE_BUILDER:-} == harvester ]] || {
    echo 'Host runtime is restricted to CI or the owned Harvester builder' >&2; exit 2;
}
candidate=${1:?Expected verified candidate artifact directory}
: "${CI_ARTIFACT_DIR:?Set receipt directory}"
mkdir -p "$CI_ARTIFACT_DIR"
for phase in import overlay boot; do
    timeout --kill-after=60s 160m bash scripts/ci/candidate-runtime.sh "$candidate" "$phase" 2>&1 | tee "$CI_ARTIFACT_DIR/host-$phase.log"
done
