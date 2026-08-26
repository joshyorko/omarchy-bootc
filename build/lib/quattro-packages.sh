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
