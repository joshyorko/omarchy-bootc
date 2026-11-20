#!/usr/bin/env bash
set -euo pipefail

pacman_config="${1:?pacman config path is required}"
repository_fragment="${2:?repository fragment path is required}"
temporary_config="$(mktemp)"
trap 'rm -f "${temporary_config}"' EXIT

awk '
    /^\[(core|extra|multilib|omarchy)\]$/ { skipping = 1; next }
    /^\[[^]]+\]$/ { skipping = 0 }
    !skipping { print }
' "${pacman_config}" >"${temporary_config}"

install -m 0644 "${temporary_config}" "${pacman_config}"
printf '\n' >>"${pacman_config}"
cat "${repository_fragment}" >>"${pacman_config}"
