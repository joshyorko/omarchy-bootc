#!/usr/bin/env bash
set -euo pipefail

if getent passwd omarchy >/dev/null; then
    echo 'Publishable image contains the acceptance user' >&2
    exit 1
fi

if [[ -e /etc/sudoers.d/90-omarchy-acceptance ]]; then
    echo 'Publishable image contains acceptance sudo credentials' >&2
    exit 1
fi
