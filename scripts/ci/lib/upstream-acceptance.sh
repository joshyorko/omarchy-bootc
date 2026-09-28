#!/usr/bin/env bash

run_upstream_acceptance() {
    local upstream_dir="$1"
    local artifact_dir="$2"
    local ssh_user="$3"
    local ssh_port="$4"
    local ssh_password="$5"
    local acceptance_status=0

    # scp uses -P rather than ssh's -p. Transfer only tests, never the source .git.
    if ! sshpass -p "${ssh_password}" scp -r -P "${ssh_port}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${upstream_dir}/test" "${ssh_user}@127.0.0.1:upstream-acceptance-test"; then
        return 1
    fi
    if ! run_guest 'mkdir -p "$HOME/upstream-acceptance/test"; cp -a "$HOME/upstream-acceptance-test/." "$HOME/upstream-acceptance/test/"'; then
        return 1
    fi
    if ! run_guest 'env OMARCHY_ACCEPTANCE_DIR="$HOME/acceptance-receipts/upstream" OMARCHY_ACCEPTANCE_TEST_TIMEOUT=120 timeout 20m bash "$HOME/upstream-acceptance/test/acceptance"' \
        2>&1 | tee "${artifact_dir}/upstream-acceptance.log"; then
        acceptance_status=1
    fi
    return "${acceptance_status}"
}
