#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_url="$(sed -n '1p' "${ROOT_DIR}/sources/omarchy-quattro.source")"
pinned_sha="$(sed -n '1p' "${ROOT_DIR}/sources/omarchy-quattro.revision")"
branch="${OMARCHY_UPSTREAM_REF:-quattro}"
title='[upstream] Omarchy Quattro update available'

live_sha="$(git ls-remote "$source_url" "refs/heads/${branch}" | awk 'NR == 1 { print $1 }')"
[[ "$live_sha" =~ ^[[:xdigit:]]{40}$ ]] || {
    echo "Unable to resolve ${source_url} ${branch}" >&2
    exit 1
}
[[ "$pinned_sha" =~ ^[[:xdigit:]]{40}$ ]] || {
    echo "Invalid pinned Omarchy revision: ${pinned_sha}" >&2
    exit 1
}

if [[ "$live_sha" == "$pinned_sha" ]]; then
    echo "Omarchy Quattro is current at ${pinned_sha}"
    exit 0
fi

repo="${GITHUB_REPOSITORY:-joshyorko/omarchy-bootc}"
body=$(cat <<EOF
The canonical Omarchy Quattro ref moved without changing this repository's pinned source.

- Repository: ${source_url}
- Tracking ref: ${branch}
- Pinned SHA: [${pinned_sha}](https://github.com/omacom/omarchy/commit/${pinned_sha})
- Live SHA: [${live_sha}](https://github.com/omacom/omarchy/commit/${live_sha})

This is advisory only. Do not repin, rebuild, or publish from this tracker. Update
\`sources/omarchy-quattro.revision\` in a reviewed pull request, then let the normal
candidate build publish the accepted \`:testing\` image. \`:stable\` is not managed
by this repository.
EOF
)

existing="$(gh issue list --repo "$repo" --state open --search "${title} in:title" --json number --jq '.[0].number // empty')"
if [[ -n "$existing" ]]; then
    gh issue edit "$existing" --repo "$repo" --title "$title" --body "$body"
    echo "Updated ${repo}#${existing}"
else
    gh issue create --repo "$repo" --title "$title" --body "$body"
fi
