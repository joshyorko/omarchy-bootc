#!/usr/bin/env bash
# Run only on a GitHub runner or the dedicated Harvester Ubuntu machine.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true || ${OMARCHY_REMOTE_BUILDER:-} == harvester ]] || {
    echo 'Refusing to start a Dagger engine on the workstation' >&2; exit 2;
}
root=${OMARCHY_ENGINE_ROOT:-/var/lib/containers/omarchy-dagger}
engine=omarchy-dagger-v0.20.6
# Resolved by the real Harvester pull of the official v0.20.6 engine.
image=registry.dagger.io/engine@sha256:78cdac5f0ab478a82deb9c8bc3490f56a5be9a9c8bc424584771f4634f04a3a0
sudo -n mkdir -p "$root"
root=$(realpath -- "$root")
if ! docker image inspect "$image" >/dev/null 2>&1; then docker pull "$image" >&2; fi
expected_image=$(docker image inspect "$image" --format '{{.Id}}')
free=$(df -Pk "$root" | awk 'NR==2 {print $4}')
((free >= 30 * 1024 * 1024)) || { echo 'Need 30 GiB genuinely free for Dagger' >&2; exit 1; }
cpu_set=$(python3 -c 'import os; print(",".join(map(str, sorted(os.sched_getaffinity(0))[:4])))')
if ! docker container inspect "$engine" >/dev/null 2>&1; then
    docker create --name "$engine" --privileged --cgroupns=private \
        --cpus=4 --cpuset-cpus="$cpu_set" --memory=12g --memory-swap=14g --pids-limit=4096 \
        --restart=unless-stopped -v "$root:/var/lib/dagger" "$image" --debug >/dev/null
fi
actual_image=$(docker inspect "$engine" --format '{{.Image}}')
[[ $actual_image == "$expected_image" ]] || { echo 'Existing Dagger engine image differs from pinned digest' >&2; exit 1; }
docker inspect "$engine" | python3 -c '
import json,sys
engine=json.load(sys.stdin)[0]
mounts=[m for m in engine["Mounts"] if m["Destination"]=="/var/lib/dagger"]
assert len(mounts)==1 and mounts[0]["Type"]=="bind" and mounts[0]["Source"]==sys.argv[1], "Dagger engine cache mount differs from requested storage root"
assert engine["HostConfig"]["CgroupnsMode"]=="private", "Dagger engine cgroup namespace differs"
' "$root"
limits=$(docker inspect "$engine" --format '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.PidsLimit}} {{.HostConfig.CpusetCpus}}')
[[ $limits == "4000000000 12884901888 15032385536 4096 $cpu_set" ]]
docker start "$engine" >/dev/null
actual=$(docker exec "$engine" cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max /sys/fs/cgroup/cpu.max /sys/fs/cgroup/pids.max)
[[ $actual == $'12884901888\n2147483648\n400000 100000\n4096' ]]
printf '_EXPERIMENTAL_DAGGER_RUNNER_HOST=docker-container://%s\n' "$engine"
