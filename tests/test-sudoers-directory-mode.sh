#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Exercise the actual directory-creation commands from each effective writer.
# Pacman preserves existing directory modes when another package owns the path;
# omarchy-settings and asdcontrol require 0750 (candidate run 36440180513).
for writer in Containerfile build/install-bootc-update.sh build/acceptance-firstboot.sh; do
    command="$(sed -n '/^\(RUN \)\?install -d .* \/etc\/sudoers\.d/ { s/^RUN //; s/ &&.*//; p; }' "$ROOT_DIR/$writer")"
    [[ -n "$command" ]] || { printf 'Missing sudoers directory writer: %s\n' "$writer" >&2; exit 1; }
    command="${command//\/etc\/sudoers.d/$fixture/sudoers.d}"
    for initial in absent 750; do
        rm -rf "$fixture/sudoers.d"
        if [[ "$initial" == 750 ]]; then
            install -d -m 0750 "$fixture/sudoers.d"
            printf 'preserved policy\n' >"$fixture/sudoers.d/policy"
            chmod 0440 "$fixture/sudoers.d/policy"
        fi
        bash -c "$command"
        actual="$(stat -c %a "$fixture/sudoers.d")"
        [[ "$actual" == 750 ]] || {
            printf 'FAIL: %s (%s) changed package directory mode to %s; expected 750\n' "$writer" "$initial" "$actual" >&2
            exit 1
        }
        if [[ "$initial" == 750 ]]; then
            [[ "$(cat "$fixture/sudoers.d/policy")" == 'preserved policy' ]]
            [[ "$(stat -c %a "$fixture/sudoers.d/policy")" == 440 ]]
        fi
    done
done
printf 'PASS: all sudoers directory writers preserve package mode and existing policies\n'
