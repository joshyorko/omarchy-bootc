#!/usr/bin/env bash
# Control-plane only. Adapted from homebrew-tools' bundle/SSH/lock pattern.
# All Docker, Dagger, Podman, OCI and VM work executes on the Devsy machine.
set -euo pipefail
mode=${1:-probe}
[[ $mode == probe || $mode == build ]] || { echo 'Usage: devsy-dagger.sh [probe|build]' >&2; exit 2; }
machine=${OMARCHY_MACHINE:-omarchy-ac-0b534}
[[ $machine =~ ^omarchy-[a-z0-9-]+$ ]]
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
[[ -z $(git status --porcelain) ]] || { echo 'Commit the exact source checkpoint before remote proof' >&2; exit 1; }
head=$(git rev-parse HEAD)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/codex-omarchy-dagger-XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
# No local engine startup, image pull or OCI transfer, including on remote error.
git bundle create "$scratch/source.bundle" HEAD
git archive HEAD >"$scratch/source.tar"
remote() { devsy --no-status machine ssh "$machine" --command "$1"; }
# Static remote command: paths returned below are validated before interpolation.
# shellcheck disable=SC2016 # HOME expands on the remote Ubuntu machine.
run=$(remote 'mkdir -p "$HOME/omarchy-builds"; mktemp -d "$HOME/omarchy-builds/run.XXXXXXXX"')
[[ $run =~ ^/home/[a-zA-Z0-9_-]+/omarchy-builds/run\.[a-zA-Z0-9]+$ ]]
printf 'Retained remote run: %s:%s\n' "$machine" "$run"
tar -C "$scratch" -cf - source.bundle source.tar | remote "tar -xf - -C $run"
remote "mkdir $run/source; tar -xf $run/source.tar -C $run/source; git clone --mirror $run/source.bundle $run/source/.git; git -C $run/source config core.bare false; git -C $run/source reset --mixed HEAD"
# Source is immutable and argv values are validated, not shell-quoted user text.
remote "bash -o pipefail -c 'cd $run/source && OMARCHY_REMOTE_BUILDER=harvester timeout --kill-after=60s 6h bash scripts/ci/devsy-dagger-worker.sh $mode $run $head 2>&1 | tee $run/worker.log'"
