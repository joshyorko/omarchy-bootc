#!/usr/bin/env bash
# Lightweight control-plane observer for a post-merge run with no open image PR.
# It only reads that run and reports its result to the installer follow-up's SHA.
# It never builds, merges, signs, publishes or installs anything.
set -euo pipefail
run=${1:?Run ID}; source_sha=${2:?Expected main source}; target_sha=${3:?Follow-up check SHA}
[[ $run =~ ^[0-9]+$ && $source_sha =~ ^[a-f0-9]{40}$ && $target_sha =~ ^[a-f0-9]{40}$ ]]
repository=joshyorko/omarchy-bootc
url="https://github.com/$repository/actions/runs/$run"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/codex-main-observer-XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
post() {
    gh api --method POST "repos/$repository/statuses/$target_sha" \
        -f "state=$1" -f 'context=Trusted testing image and ISO build' \
        -f "target_url=$url" -f "description=$2" >/dev/null
}
post pending "Waiting for trusted main run $run"
watch_status=0
timeout --signal=TERM --kill-after=15s 6h gh run watch "$run" --repo "$repository" \
    --exit-status --interval 60 || watch_status=$?
if ! gh api "repos/$repository/actions/runs/$run" >"$scratch/run.json"; then
    post error 'Observer could not verify the workflow result; inspect run'
    exit 1
fi
if ! jq -e --arg source "$source_sha" '.head_sha == $source and .status == "completed"' "$scratch/run.json" >/dev/null; then
    post error "Observer stopped ($watch_status) without verified completion"
    exit 1
fi
if jq -e '.conclusion == "success"' "$scratch/run.json" >/dev/null; then
    post success "Trusted main run $run passed; installer testing remains separate"
else
    post failure "Trusted main run $run failed; inspect actual job logs"
    exit 1
fi
