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
# Rootful containers-storage ancestors can be mode 0700. Keep the shared lock
# in a root-owned, traversable namespace; never change the store's permissions.
lock_root=/run/omarchy-bootc-runtime-locks
sudo -n install -d -m 0755 -o root -g root "$lock_root"
# touch preserves an existing inode/lock, including while another worker owns it.
sudo -n touch "$lock_root/host-runtime.lock"
sudo -n chmod 0644 "$lock_root/host-runtime.lock"
exec 9<"$lock_root/host-runtime.lock"
flock -n 9 || { echo 'Another host acceptance owns the shared QEMU/Podman resources' >&2; exit 1; }
for phase in import overlay boot; do
    timeout --kill-after=60s 160m bash scripts/ci/candidate-runtime.sh "$candidate" "$phase" 2>&1 | tee "$CI_ARTIFACT_DIR/host-$phase.log"
done
