#!/usr/bin/env bash
# Tiny real image-store regression, before any costly compiler stage.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true || ${OMARCHY_REMOTE_BUILDER:-} == harvester || -n ${PIPELINE_EXECUTION_ID:-} ]] || exit 2
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/omarchy-parent-probe-XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
printf 'accepted parent\n' >"$scratch/original"
printf 'different rebuilt parent\n' >"$scratch/changed"
printf 'child\n' >"$scratch/child"
printf 'FROM scratch\nCOPY original /proof\n' >"$scratch/Parentfile"
sudo -n podman build --pull=never --format=oci --iidfile "$scratch/parent.id" -f "$scratch/Parentfile" "$scratch" >/dev/null
parent=$(cat "$scratch/parent.id")
printf 'FROM scratch AS base\nCOPY changed /proof\nFROM base AS child\nCOPY child /child\n' >"$scratch/Containerfile"
python3 "$root/scripts/ci/pin-stage-parent.py" "$scratch/Containerfile" child base "$parent" "$scratch/Pinnedfile"
sudo -n podman build --pull=never --format=oci --target child --iidfile "$scratch/child.id" -f "$scratch/Pinnedfile" "$scratch" >/dev/null
# The unprivileged runner owns this receipt directory.
# shellcheck disable=SC2024
sudo -n podman image inspect "$parent" "$(cat "$scratch/child.id")" >"$scratch/images.json"
python3 - "$scratch/images.json" <<'PY'
import json,sys
parent,child=json.load(open(sys.argv[1]))
before,after=parent['RootFS']['Layers'],child['RootFS']['Layers']
assert before and len(after)==len(before)+1 and after[:len(before)]==before, 'local immutable parent was rebuilt/replaced'
print('PASS: actual Podman child inherits the recorded immutable parent, not the changed source stage')
PY
