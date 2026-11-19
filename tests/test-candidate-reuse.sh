#!/usr/bin/env bash
set -euo pipefail

helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/scripts/ci/verify-candidate-reuse.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "${fixture}"' EXIT
cd "${fixture}"
git init -q
git config user.email fixture@example.invalid
git config user.name Fixture
mkdir -p scripts/ci
printf 'original\n' >Containerfile
printf 'original\n' >scripts/ci/candidate-runtime.sh
git add .
git commit -qm baseline
source_head="$(git rev-parse HEAD)"
bash "${helper}" "${source_head}" HEAD
printf 'diagnostic\n' >>scripts/ci/candidate-runtime.sh
git add .
git commit -qm harness
bash "${helper}" "${source_head}" HEAD
printf 'disposable overlay\n' >scripts/ci/acceptance-overlay.Containerfile
git add .
git commit -qm overlay
bash "${helper}" "${source_head}" HEAD
printf 'changed image\n' >>Containerfile
git add .
git commit -qm image
if bash "${helper}" "${source_head}" HEAD; then
    echo 'FAIL: changed image input accepted for reuse' >&2
    exit 1
fi
if bash "${helper}" invalid HEAD; then
    echo 'FAIL: invalid source identity accepted' >&2
    exit 1
fi
printf 'candidate reuse identity tests passed\n'
