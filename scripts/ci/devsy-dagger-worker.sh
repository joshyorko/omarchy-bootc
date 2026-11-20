#!/usr/bin/env bash
set -euo pipefail
[[ ${OMARCHY_REMOTE_BUILDER:-} == harvester ]]
# shellcheck disable=SC1091
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]]
mode=${1:?}; run=${2:?}; head=${3:?}
[[ $mode == probe || $mode == build ]]
[[ $run =~ ^/home/[a-zA-Z0-9_-]+/omarchy-builds/run\.[a-zA-Z0-9]+$ && $head =~ ^[[:xdigit:]]{40}$ ]]
[[ $(git rev-parse HEAD) == "$head" && -z $(git status --porcelain) ]]
exec 9>"$HOME/omarchy-builds/engine.lock"
flock -n 9 || { echo 'Another Omarchy pipeline owns this engine' >&2; exit 1; }
export PATH="$HOME/omarchy-builds/tools:$PATH"
[[ $(dagger version | awk '{print $2}') == v0.20.6 ]]
export _EXPERIMENTAL_DAGGER_RUNNER_HOST
_EXPERIMENTAL_DAGGER_RUNNER_HOST=$(bash scripts/ci/dagger-engine.sh | sed -n 's/^_EXPERIMENTAL_DAGGER_RUNNER_HOST=//p')
[[ $_EXPERIMENTAL_DAGGER_RUNNER_HOST == docker-container://omarchy-dagger-v0.20.6 ]]
# shellcheck disable=SC2317,SC2329 # Called by EXIT.
finish() {
    local rc=$?
    printf '%s\n' "$rc" >"$run/exit-code"
    df -h / >"$run/host-disk-after.txt"
}
trap finish EXIT
printf '%s\n' "$head" >"$run/source-head"
dagger version >"$run/dagger-version.txt"
docker exec omarchy-dagger-v0.20.6 cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max >"$run/engine-limits.txt"
dagger call nested-probe --git-bundle="$run/source.bundle" --source-head="$head" --execution-id="$(date +%s)-probe" export --path="$run/probe"
dagger call check-result --status="$run/probe/exit-code"
if [[ $mode == build ]]; then
    for pass in cold warm; do
        free=$(df -Pk /var/lib/containers/omarchy-dagger | awk 'NR==2 {print $4}')
        ((free >= 30 * 1024 * 1024))
        start=$(date +%s)
        dagger call candidate-build --git-bundle="$run/source.bundle" --source-head="$head" --execution-id="$(date +%s)-$pass" export --path="$run/$pass"
        dagger call check-result --status="$run/$pass/exit-code"
        printf '%s\t%s\t%s\n' "$pass" "$start" "$(date +%s)" >>"$run/timings.tsv"
    done
fi
# Exports stay here. Host QEMU acceptance is a separate explicit common boundary.
