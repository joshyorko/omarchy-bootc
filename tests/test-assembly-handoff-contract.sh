#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${ROOT_DIR}/.github/workflows/assembly.yml"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

test -s "${WORKFLOW}" || fail "assembly workflow is missing"
grep -Fq 'github.event.pull_request.head.sha || github.event.inputs.source_ref || github.sha' "${WORKFLOW}" ||
  fail "assembly workflow does not pin the exact subject"
grep -Fq './scripts/ci/candidate-build.sh foundation' "${WORKFLOW}" ||
  fail "assembly workflow does not prove the foundation first"
grep -Fq './scripts/ci/candidate-build.sh assembly' "${WORKFLOW}" ||
  fail "assembly workflow does not build the assembly target"
grep -Fq 'omarchy-bootc.assembly/v1' "${WORKFLOW}" ||
  fail "assembly receipt schema is not verified"
grep -Fq '.upstream_pins.omarchy_quattro_revision' "${WORKFLOW}" ||
  fail "Omarchy source provenance is not verified"
grep -Fq '.upstream_pins.omarchy_version' "${WORKFLOW}" ||
  fail "Omarchy package version is not verified"
grep -Fq 'actions/upload-artifact@v4' "${WORKFLOW}" ||
  fail "assembly handoff is not retained"
! grep -Fq 'vm-smoke.sh' "${WORKFLOW}" ||
  fail "assembly workflow must not invoke the VM path"

printf 'assembly handoff workflow contract passed\n'
