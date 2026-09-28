#!/usr/bin/env bash
# Normalize only the designated artifact tree. Explicit IDs override sudo's
# initiating runner; a direct root caller must provide IDs for another owner.
normalize_runtime_artifacts() {
    local tree="$1" uid="${2:-${SUDO_UID:-$(id -u)}}" gid="${3:-${SUDO_GID:-$(id -g)}}"
    local helper
    helper="$(dirname "${BASH_SOURCE[0]}")/runtime-artifacts.py"
    if (( EUID == 0 )); then
        python3 "${helper}" "${tree}" "${uid}" "${gid}"
    else
        sudo -n python3 "${helper}" "${tree}" "${uid}" "${gid}"
    fi
}
