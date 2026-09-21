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

resolve_archived_apple_firmware() {
    local config="$1" sources="$2" workdir="$3"
    local url checksum filename metadata
    url="$(cat "${sources}/apple-bcm-firmware.source")" || return 1
    read -r checksum filename <"${sources}/apple-bcm-firmware.sha256" || return 1
    [[ "${checksum}" =~ ^[[:xdigit:]]{64}$ && "${filename}" == 'apple-bcm-firmware-14.0-1-any.pkg.tar.zst' ]] || return 1
    [[ "${url##*/}" == "${filename}" ]] || return 1
    # This is an archived native payload from an already configured authority,
    # not another repository or an alias for the incompatible firmware fetcher.
    grep -Fxq "Server = ${url%/*}" "${config}" || return 1
    mkdir -p "${workdir}" || return 1
    curl --fail --silent --show-error --location --max-time 60 --retry 2 \
        "${url}" -o "${workdir}/${filename}" || return 1
    printf '%s  %s\n' "${checksum}" "${workdir}/${filename}" | sha256sum -c - >/dev/null || return 1
    metadata="$(tar -xOf "${workdir}/${filename}" .PKGINFO)" || return 1
    grep -Fxq 'pkgname = apple-bcm-firmware' <<<"${metadata}" || return 1
    grep -Fxq 'pkgver = 14.0-1' <<<"${metadata}" || return 1
    printf 'archive %s sha256:%s\n' "${url}" "${checksum}"
    LC_ALL=C pacman --config "${config}" -Up --print-format '%n %v' "${workdir}/${filename}"
}

resolve_quattro_optional_package() {
    local config="$1" package="$2" report="$3" sources="$4" workdir="$5"
    local resolution archived
    if resolution="$(LC_ALL=C pacman --config "${config}" -Sp --print-format '%n %v' "${package}" 2>&1)"; then
        printf 'resolvable %s\n%s\n' "${package}" "${resolution}" >>"${report}"
    elif [[ "${package}" == apple-bcm-firmware ]] &&
        grep -Fxq 'error: target not found: apple-bcm-firmware' <<<"${resolution}"; then
        if archived="$(resolve_archived_apple_firmware "${config}" "${sources}" "${workdir}" 2>&1)"; then
            printf 'resolvable-archive %s\n%s\n' "${package}" "${archived}" >>"${report}"
        else
            printf 'unresolved %s\n%s\n%s\n' "${package}" "${resolution}" "${archived}" >>"${report}"
        fi
    else
        printf 'unresolved %s\n%s\n' "${package}" "${resolution}" >>"${report}"
    fi
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
            /^(resolvable|resolvable-archive|unresolved) / { failed = ($1 == "unresolved") }
            failed && lines++ < 80 { print }
        ' "${report}" >&2
        return 1
    fi

    resolved_count="$(grep -Ec '^resolvable(-archive)? ' "${report}" || true)"
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
