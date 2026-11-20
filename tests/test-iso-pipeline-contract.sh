#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "${ROOT_DIR}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
hook = (root / 'iso_files/configure_iso_anaconda.sh.in').read_text()
dagger = (root / '.dagger/main.go').read_text()
reusable_text = (root / '.github/workflows/reusable-build-iso.yml').read_text()
dispatch_text = (root / '.github/workflows/build-iso.yml').read_text()
build_text = (root / '.github/workflows/build.yml').read_text()
justfile = (root / 'Justfile').read_text()

# P1-04: initial-account UI must not be hidden in Anaconda.
hook_active = '\n'.join(
    line for line in hook.splitlines() if not line.lstrip().startswith('#')
)
for forbidden in ('UserSpoke', 'PasswordSpoke', 'anaconda-screen-accounts'):
    assert forbidden not in hook_active, f'Anaconda hook hides initial account creation: {forbidden}'
assert '/var/lib/omarchy-bootc/installer-origin' in hook, 'Anaconda post-script omits installer-origin marker'

# P1-03: separate immutable install digest from mutable tracking stream.
assert 'INSTALL_IMAGE_REF="@@INSTALL_IMAGE_REF@@"' in hook
assert 'TRACKING_IMAGE_REF="@@TRACKING_IMAGE_REF@@"' in hook
assert 'ostreecontainer --url=${INSTALL_IMAGE_REF}' in hook
assert 'bootc switch --mutate-in-place --transport registry ${TRACKING_IMAGE_REF}' in hook
assert 'bootc switch --mutate-in-place --transport registry ${INSTALL_IMAGE_REF}' not in hook

# Dagger module refuses mutable installImageRef and separates trackingImageRef.
assert 'immutableRefPattern.MatchString(installImageRef)' in dagger
assert 'trackingRefPattern.MatchString(trackingImageRef)' in dagger
assert '@@TRACKING_IMAGE_REF@@' in dagger

# Reusable ISO workflow enforces immutable install ref, source SHA, and trust verification.
assert re.search(r'^\s+install_image_ref:\n(?:.*\n){0,4}?\s+required:\s*true\b', reusable_text, re.M)
assert re.search(r'^\s+install_source_sha:\n(?:.*\n){0,4}?\s+required:\s*true\b', reusable_text, re.M)
assert 'tracking_image_ref:' in reusable_text
assert 'verify-published-image-trust.sh' in reusable_text
assert '--tracking-image-ref' in reusable_text
assert 'Refusing mutable or malformed install_image_ref' in reusable_text

# Manual dispatch ISO workflow requires immutable image ref + source SHA.
assert re.search(r'^\s+install_image_ref:\n(?:.*\n){0,4}?\s+required:\s*true\b', dispatch_text, re.M)
assert re.search(r'^\s+install_source_sha:\n(?:.*\n){0,4}?\s+required:\s*true\b', dispatch_text, re.M)

# Main build workflow binds ISO to published immutable image_ref and github.sha.
iso_block = build_text.split('  build_installer_iso:\n', 1)[1]
assert 'needs.publish.outputs.image_ref' in iso_block
assert 'install_source_sha: ${{ github.sha }}' in iso_block

# Local Justfile binds verified immutable ref and passes tracking stream.
assert 'verify-published-image-trust.sh' in justfile
assert '--tracking-image-ref' in justfile

print('PASS: ISO pipeline binds verified immutable image/source, separates tracking stream, and restores initial-account UI')
PY
