#!/usr/bin/env bash
set -euo pipefail

# Matches omacom-io/omarchy-iso builder/build-iso.sh for the input consumed by
# v4.0.1 install/user/mise-work.sh during iso-chroot finalization.
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
