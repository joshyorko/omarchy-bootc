#!/usr/bin/env bash
set -euo pipefail

# Matches the current omacom/omarchy-iso Quattro builder input consumed by
# the user mise finalization path.
node_dist_url="https://nodejs.org/dist/latest"
shasums="$(curl -fsSL "${node_dist_url}/SHASUMS256.txt")"
node_filename="$(awk '$2 ~ /^node-v.*-linux-x64\.tar\.gz$/ { print $2 }' <<<"${shasums}")"
node_sha="$(awk '$2 ~ /^node-v.*-linux-x64\.tar\.gz$/ { print $1 }' <<<"${shasums}")"

[[ -n "${node_filename}" ]]
[[ -n "${node_sha}" ]]
[[ "${node_filename}" != *$'\n'* ]]

install -d -m 0755 /usr/lib/omarchy-acceptance/packages
curl -fsSL "${node_dist_url}/${node_filename}" -o "/usr/lib/omarchy-acceptance/packages/${node_filename}"
printf '%s  %s\n' "${node_sha}" "/usr/lib/omarchy-acceptance/packages/${node_filename}" | sha256sum -c -
printf '%s  %s\n' "${node_sha}" "${node_filename}" > /usr/lib/omarchy-acceptance/packages/SHASUMS256.txt
