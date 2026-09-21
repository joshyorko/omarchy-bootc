#!/usr/bin/env bash

read_quattro_package_manifest() {
    local manifest="$1"

    awk '
        {
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
        }
        $0 != "" && $0 !~ /^#/ { print }
    ' "${manifest}"
}

verify_optional_resolution_report() {
    local report="${1:?optional resolution report path is required}"
    local resolved_count

    [[ -s "${report}" ]] || {
        printf 'Missing or empty optional package resolution report: %s\n' "${report}" >&2
        return 1
    }
    if grep -q '^unresolved ' "${report}"; then
        printf 'Authoritative optional packages could not be resolved:\n' >&2
        awk '
            /^(resolvable|unresolved) / { failed = ($1 == "unresolved") }
            failed && lines++ < 80 { print }
        ' "${report}" >&2
        return 1
    fi

    resolved_count="$(grep -c '^resolvable ' "${report}" || true)"
    [[ "${resolved_count}" -gt 0 ]]
}

remove_optional_repository_database() {
    local database_path="${1:?pacman database path is required}"
    local repository="${2:?repository name is required}"
    local sync_path="${database_path%/}/sync"

    [[ -d "${sync_path}" ]] || return 1
    find "${sync_path}" -maxdepth 1 \
        -name "${repository}.db*" -delete
}
