#!/usr/bin/env bash
# Dagger worker entrypoint; exports failures so the mandatory CheckResult gate
# can fail after receipts/logs have been retained. Never use export as a verdict.
set -euo pipefail
mkdir -p /out
[[ ! -f /out/exit-code || $(cat /out/exit-code) == 0 ]] || exit 0
phase=${DAGGER_PHASE:?}
start=$(date +%s)
finish() {
    local rc=$?
    printf '%s\n' "$rc" >/out/exit-code
    printf '%s\t%s\t%s\t%s\n' "$phase" "$start" "$(date +%s)" "$rc" >>/out/timings.tsv
    df -h /var/lib/containers >/out/disk.txt
    # Deliberate evidence transport; CheckResult is mandatory after export.
    exit 0
}
trap finish EXIT
[[ ${EXPECTED_SOURCE_HEAD:?} =~ ^[[:xdigit:]]{40}$ ]]
if [[ ! -d .git ]]; then
    git clone --mirror /input/source.bundle .git
    git config core.bare false
    git reset --mixed HEAD
fi
[[ $(git rev-parse HEAD) == "$EXPECTED_SOURCE_HEAD" ]]
[[ -z $(git status --porcelain) ]]
free=$(df -Pk /var/lib/containers | awk 'NR==2 {print $4}')
((free >= 30 * 1024 * 1024))
export CANDIDATE_MIN_FREE_GIB=30 CANDIDATE_MAX_LOG_BYTES=52428800
export FOUNDATION_IMAGE_REF=localhost/omarchy-bootc:foundation
export ASSEMBLY_IMAGE_REF=localhost/omarchy-bootc:assembly
export INTEGRATION_IMAGE_REF=localhost/omarchy-bootc:integration
case "$phase" in
    source)
        while IFS= read -r -d '' script; do bash -n "$script"; shellcheck "$script"; done < <(find build scripts tests custom/first-boot transition -name '*.sh' -print0)
        while IFS= read -r -d '' script; do bash -n "$script"; shellcheck "$script"; done < <(find custom/bootc -type f ! -name '*.service' -print0)
        for test in tests/test-*.sh; do bash "$test"; done > /out/source-tests.log 2>&1
        ;;
    probe)
        podman info >/out/nested-podman-info.txt
        failed=0
        rc=0
        podman run --rm --pull=missing docker.io/library/alpine:3.21 sh -ceu 'test "$(id -u)" = 0; mount | head -n 4' >/out/nested-run.txt 2>&1 || rc=$?
        printf '%s\n' "$rc" >/out/nested-run.exit-code
        ((rc == 0)) || failed=1
        mkdir /out/probe-context
        printf 'FROM docker.io/library/alpine:3.21\nRUN printf nested-overlay >/proof\n' >/out/probe-context/Containerfile
        for pass in cold warm; do
            rc=0
            /usr/bin/time -v -o "/out/probe-$pass.resources" podman build --pull=never --layers -t localhost/omarchy-nested:proof /out/probe-context >"/out/probe-$pass.log" 2>&1 || rc=$?
            printf '%s\n' "$rc" >"/out/probe-$pass.exit-code"
            ((rc == 0)) || failed=1
        done
        podman image inspect localhost/omarchy-nested:proof >/out/probe-image.json || failed=1
        ((failed == 0))
        ;;
    preflight|packages|foundation|assembly|integration|build)
        /usr/bin/time -v -o "/out/$phase.resources" timeout --kill-after=60s 60m bash scripts/ci/candidate-build.sh "$phase" >"/out/$phase.log" 2>&1
        ;;
    identity)
        mkdir -p /out/final
        shopt -s nullglob
        receipts=(/out/candidate/*candidate*.receipt.json)
        archives=(/out/candidate/*candidate*.oci.tar)
        [[ ${#receipts[@]} == 1 && ${#archives[@]} == 1 ]]
        cp --reflink=auto "${receipts[0]}" "${archives[0]}" /out/final/
        export CI_ARTIFACT_DIR=/out/identity CANDIDATE_SOURCE_HEAD=$EXPECTED_SOURCE_HEAD
        timeout --kill-after=60s 20m bash scripts/ci/candidate-runtime.sh /out/final import > /out/identity.log 2>&1
        ;;
    *) echo 'Unknown Dagger candidate phase' >&2; exit 2 ;;
esac
