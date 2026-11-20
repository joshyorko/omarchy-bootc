#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# These real entrypoints must reject an ordinary control-plane shell before
# invoking Docker, apt, Podman or VM tools. No heavyweight tools are mocked/run.
for script in dagger-engine.sh dagger-host-runtime.sh prepare-ubuntu-runner.sh; do
    rc=0
    env -u GITHUB_ACTIONS -u OMARCHY_REMOTE_BUILDER bash "$root/scripts/ci/$script" >/dev/null 2>&1 || rc=$?
    [[ $rc == 2 ]] || { echo "FAIL: workstation guard in $script" >&2; exit 1; }
done
printf 'PASS: Dagger/host runner entrypoints refuse workstation execution\n'
