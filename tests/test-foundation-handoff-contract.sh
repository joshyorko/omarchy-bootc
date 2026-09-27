#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
workflow="${root_dir}/.github/workflows/foundation.yml"

test -s "${workflow}"
grep -Fq 'ref: ${{ github.event.pull_request.head.sha || github.event.inputs.source_ref || github.sha }}' "${workflow}"
grep -Fq './scripts/ci/candidate-build.sh foundation' "${workflow}"
grep -Fq 'omarchy-bootc.foundation/v1' "${workflow}"
grep -Fq '.source_sha == $head' "${workflow}"
grep -Fq '.oci_manifest_digest' "${workflow}"
grep -Fq '.archive_sha256' "${workflow}"
grep -Fq 'actions/upload-artifact@v4' "${workflow}"
grep -Fq 'compression-level: 0' "${workflow}"
! grep -Fq -- '--target quattro-assembly' "${workflow}"
! grep -Fq -- '--target final' "${workflow}"

printf 'foundation handoff workflow contract passed\n'
