#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
filter="${root}/scripts/ci/bootc-backend.jq"
# v1.16.13 BootEntry backend fields are siblings of ImageStatus.
[[ $(jq -er -f "$filter" <<<'{"status":{"booted":{"image":{"imageDigest":"sha256:a"},"composefs":{"verity":"a"},"ostree":null},"staged":{"ostree":{}}}}') == composefs ]]
[[ $(jq -er -f "$filter" <<<'{"status":{"booted":{"image":{},"ostree":{"checksum":"a"},"composefs":null},"staged":{"composefs":{}}}}') == ostree ]]
for invalid in \
    '{"status":{"booted":null,"staged":{"composefs":{}}}}' \
    '{"status":{"booted":{"image":{"store":"composefs"}}}}' \
    '{"status":{"booted":{"composefs":{},"ostree":{}}}}' \
    '{"status":{"booted":{"composefs":"invalid"}}}'; do
    if jq -er -f "$filter" <<<"$invalid" >/dev/null 2>&1; then
        printf 'Accepted invalid or non-booted backend: %s\n' "$invalid" >&2
        exit 1
    fi
done
printf 'PASS: booted backend schema and slot isolation\n'
