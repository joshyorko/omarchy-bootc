#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/codex-omarchy-engine-test-XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/cache"
export TEST_REAL_PYTHON TEST_REAL_REALPATH
TEST_REAL_PYTHON=$(command -v python3)
TEST_REAL_REALPATH=$(command -v realpath)
cat >"$scratch/bin/python3" <<'SH'
#!/usr/bin/env bash
if [[ $2 == *os.sched_getaffinity* ]]; then
    count=${3:-$TEST_CPUS}
    if [[ $count == 2 ]]; then echo 0,1; else echo 0,1,2,3; fi
else
    exec "$TEST_REAL_PYTHON" "$@"
fi
SH
cat >"$scratch/bin/awk" <<'SH'
#!/usr/bin/env bash
if [[ ${2:-} == /proc/meminfo ]]; then
    echo "${TEST_HOST_MEMORY_KIB:-33554432}"
else
    exec /usr/bin/awk "$@"
fi
SH
cat >"$scratch/bin/sudo" <<'SH'
#!/usr/bin/env bash
[[ $1 == -n ]] && shift
exec env TEST_VIA_SUDO=1 "$@"
SH
cat >"$scratch/bin/realpath" <<'SH'
#!/usr/bin/env bash
[[ ${TEST_VIA_SUDO:-0} == 1 ]] || { echo "realpath: ${*: -1}: Permission denied" >&2; exit 1; }
exec "$TEST_REAL_REALPATH" "$@"
SH
cat >"$scratch/bin/df" <<'SH'
#!/usr/bin/env bash
[[ ${TEST_VIA_SUDO:-0} == 1 ]] || { echo "df: ${*: -1}: Permission denied" >&2; exit 1; }
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\ntest 200000000 1 100000000 1%% /\n'
SH
cat >"$scratch/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_CALLS"
case "$1 $2" in
    'image inspect') [[ $# == 3 ]] || echo sha256:engine ;;
    'container inspect') exit 1 ;;
    'create --name') ;;
    'inspect omarchy-dagger-v0.20.6')
        if [[ $# == 2 ]]; then
            python3 -c 'import json,os; print(json.dumps([{"Mounts":[{"Destination":"/var/lib/dagger","Type":"bind","Source":os.environ["OMARCHY_ENGINE_ROOT"]}],"HostConfig":{"CgroupnsMode":"private"}}]))'
        elif [[ $4 == '{{.Image}}' ]]; then
            echo sha256:engine
        else
            affinity=$(python3 -c 'import os; print(",".join(map(str,sorted(os.sched_getaffinity(0))[:int(os.environ["TEST_CPUS"])])))')
            printf '%s %s %s 4096 %s\n' "$((TEST_CPUS*1000000000))" "${TEST_MEMORY_OVERRIDE:-$TEST_MEMORY}" "$TEST_SWAP" "$affinity"
        fi ;;
    'start omarchy-dagger-v0.20.6') ;;
    'exec omarchy-dagger-v0.20.6')
        printf '%s\n%s\n%s 100000\n4096\n' "$TEST_MEMORY" "$((TEST_SWAP-TEST_MEMORY))" "$((TEST_CPUS*100000))" ;;
    *) echo "Unexpected Docker call: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH" OMARCHY_ENGINE_ROOT="$scratch/cache" TEST_CALLS="$scratch/calls"
export TEST_CPUS=2 TEST_MEMORY=5368709120 TEST_SWAP=6442450944
OMARCHY_REMOTE_BUILDER=harvester bash "$root/scripts/ci/dagger-engine.sh" >"$scratch/result"
grep -q -- '--cpus=2 .*--memory=5g --memory-swap=6g' "$TEST_CALLS"
grep -q 'docker-container://omarchy-dagger-v0.20.6' "$scratch/result"
# An old 12-GiB engine must fail before start on the compact builder.
: >"$TEST_CALLS"
if OMARCHY_REMOTE_BUILDER=harvester TEST_MEMORY_OVERRIDE=12884901888 bash "$root/scripts/ci/dagger-engine.sh" >/dev/null 2>&1; then
    echo 'FAIL: oversized retained engine accepted' >&2; exit 1
fi
if grep -q '^start ' "$TEST_CALLS"; then
    echo 'FAIL: oversized retained engine started' >&2; exit 1
fi
export TEST_CPUS=4 TEST_MEMORY=12884901888 TEST_SWAP=15032385536
env -u OMARCHY_REMOTE_BUILDER GITHUB_ACTIONS=true bash "$root/scripts/ci/dagger-engine.sh" >/dev/null
grep -q -- '--cpus=4 .*--memory=12g --memory-swap=14g' "$TEST_CALLS"
: >"$TEST_CALLS"
if OMARCHY_REMOTE_BUILDER=harvester TEST_HOST_MEMORY_KIB=6291456 bash "$root/scripts/ci/dagger-engine.sh" >/dev/null 2>&1; then
    echo 'FAIL: engine admitted without guest RAM headroom' >&2; exit 1
fi
[[ ! -s $TEST_CALLS ]]
printf 'PASS: compact remote/standard hosted engine limits and oversized reuse rejection\n'
