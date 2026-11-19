#!/usr/bin/env bash
# Run only on a GitHub runner or the dedicated Harvester Ubuntu machine.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true || ${OMARCHY_REMOTE_BUILDER:-} == harvester ]] || {
    echo 'Refusing to start a Dagger engine on the workstation' >&2; exit 2;
}
root=${OMARCHY_ENGINE_ROOT:-/var/lib/containers/omarchy-dagger}
engine=omarchy-dagger-v0.20.6
sudo -n mkdir -p "$root"
free=$(df -Pk "$root" | awk 'NR==2 {print $4}')
((free >= 30 * 1024 * 1024)) || { echo 'Need 30 GiB genuinely free for Dagger' >&2; exit 1; }
cpu_set=$(python3 -c 'import os; print(",".join(map(str, sorted(os.sched_getaffinity(0))[:4])))')
if ! docker container inspect "$engine" >/dev/null 2>&1; then
    docker create --name "$engine" --privileged --cgroupns=private \
        --cpus=4 --cpuset-cpus="$cpu_set" --memory=12g --memory-swap=14g --pids-limit=4096 \
        --restart=unless-stopped -v "$root:/var/lib/dagger" registry.dagger.io/engine:v0.20.6 --debug >/dev/null
fi
limits=$(docker inspect "$engine" --format '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.PidsLimit}} {{.HostConfig.CpusetCpus}}')
[[ $limits == "4000000000 12884901888 15032385536 4096 $cpu_set" ]]
docker start "$engine" >/dev/null
actual=$(docker exec "$engine" cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max /sys/fs/cgroup/cpu.max /sys/fs/cgroup/pids.max)
[[ $actual == $'12884901888\n2147483648\n400000 100000\n4096' ]]
printf '_EXPERIMENTAL_DAGGER_RUNNER_HOST=docker-container://%s\n' "$engine"
