#!/usr/bin/env bash
# Remote-only worker, adapted from homebrew-tools' locked persistent builder.
# Invoke inside the dedicated acceptance Devsy container, never on Dakota.
set -euo pipefail
[[ ${OMARCHY_REMOTE_BUILDER:-} == harvester && -f /.dockerenv && -d /builds ]] || {
    echo 'Run only inside the dedicated Harvester acceptance container.' >&2
    exit 2
}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
[[ -z $(git status --porcelain) ]] || { echo 'Exact clean source required' >&2; exit 1; }
head=$(git rev-parse HEAD)
mkdir -p /builds/omarchy-bootc
exec 9>/builds/omarchy-bootc/engine.lock
flock -n 9 || { echo 'Another Omarchy build owns this cache' >&2; exit 1; }
# Guard the effective worker budget, not just the provider's requested VM size.
[[ $(cat /sys/fs/cgroup/memory.max) == 12884901888 ]]
[[ $(cat /sys/fs/cgroup/memory.swap.max) == 2147483648 ]]
[[ $(cat /sys/fs/cgroup/pids.max) == 4096 ]]
[[ $(cat /sys/fs/cgroup/cpu.max) == '400000 100000' ]]
run=$(mktemp -d "/builds/omarchy-bootc/run.${head:0:12}.XXXXXXXX")
export CANDIDATE_MIN_FREE_GIB=30 CANDIDATE_MAX_LOG_BYTES=52428800
export BUILDAH_LAYERS=true
export FOUNDATION_IMAGE_REF=localhost/omarchy-bootc:foundation
export ASSEMBLY_IMAGE_REF=localhost/omarchy-bootc:assembly
export INTEGRATION_IMAGE_REF=localhost/omarchy-bootc:integration
printf '%s\n' "$head" >"$run/source-head"
git status --porcelain >"$run/source-status"
podman version >"$run/podman-version.txt"
podman info >"$run/podman-info.txt"
podman images --no-trunc --format json >"$run/images-before.json"
cp /sys/fs/cgroup/cpu.stat "$run/cpu-before.txt"
trap 'rc=$?; printf "%s\n" "$rc" >"$run/exit-code"; cp /sys/fs/cgroup/cpu.stat "$run/cpu-after.txt"; cat /sys/fs/cgroup/memory.peak >"$run/memory-peak.txt"; df -h /builds >"$run/disk-after.txt"' EXIT
printf 'Remote evidence directory: %s\n' "$run"
phase() {
    local name=$1; shift
    local free start rc=0
    free=$(df -Pk /builds | awk 'NR==2 {print $4}')
    (( free >= 30 * 1024 * 1024 )) || { echo 'Less than 30 GiB free in /builds; refusing work' >&2; return 1; }
    start=$(date +%s)
    /usr/bin/time -v -o "$run/$name.resources" "$@" >"$run/$name.log" 2>&1 || rc=$?
    printf '%s\t%s\t%s\t%s\n' "$name" "$start" "$(date +%s)" "$rc" >>"$run/timings.tsv"
    return "$rc"
}
# Same source contracts as hosted CI; no package/image work before validation.
# shellcheck disable=SC2016 # Variables expand in the remote child Bash.
phase source-contracts bash -c '
set -euo pipefail
while IFS= read -r -d "" f; do bash -n "$f"; shellcheck "$f"; done < <(find build scripts tests custom/first-boot transition -name "*.sh" -print0)
while IFS= read -r -d "" f; do bash -n "$f"; shellcheck "$f"; done < <(find custom/bootc -type f ! -name "*.service" -print0)
for test in tests/test-*.sh; do bash "$test"; done
'
for pass in cold warm; do
    export CANDIDATE_ARTIFACT_DIR="$run/$pass/candidate"
    phase "$pass-preflight" bash scripts/ci/candidate-build.sh preflight
    phase "$pass-packages" timeout --kill-after=30s 5m bash scripts/ci/candidate-build.sh packages
    for stage in foundation assembly integration build; do
        phase "$pass-$stage" timeout --kill-after=60s 60m bash scripts/ci/candidate-build.sh "$stage"
    done
    # Retain both exact receipts; keep large exports remote. Each warm export
    # must independently pass the same archive/manifest/image import checks.
    export CI_ARTIFACT_DIR="$run/$pass/runtime" CANDIDATE_SOURCE_HEAD="$head"
    phase "$pass-identity" timeout --kill-after=60s 20m bash scripts/ci/candidate-runtime.sh "$CANDIDATE_ARTIFACT_DIR" import
    grep -h -c -- 'Using cache' "$CANDIDATE_ARTIFACT_DIR"/logs/* >"$run/$pass-cache-lines.txt" || true
done
# Record actual KVM availability. Do not claim software emulation as KVM.
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    printf 'accessible\n' >"$run/kvm.txt"
    phase overlay timeout --kill-after=60s 20m bash scripts/ci/candidate-runtime.sh "$CANDIDATE_ARTIFACT_DIR" overlay
    phase acceptance timeout --kill-after=60s 160m bash scripts/ci/candidate-runtime.sh "$CANDIDATE_ARTIFACT_DIR" boot
else
    printf 'unavailable: graphical acceptance remains on GitHub\n' >"$run/kvm.txt"
fi
# No cleanup/prune: retain failed-run evidence and warm image storage.
