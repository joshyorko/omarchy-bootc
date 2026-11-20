#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('pin', root/'scripts/ci/pin-stage-parent.py')
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)
source = (root/'Containerfile').read_text()
for stage, parent in [('foundation', 'bootcrew-system'), ('quattro-assembly', 'bootcrew-system'), ('quattro-base', 'quattro-assembly'), ('final', 'quattro-integration')]:
    image = 'a'*64
    expected = source.replace(f'FROM {parent} AS {stage}', f'FROM {image} AS {stage}', 1)
    assert pin.render(source, stage, parent, 'sha256:'+image) == expected
    assert pin.render(source, stage, parent, image) == expected
for image in ('localhost/example:latest', 'a'*63, 'a'*64+'\nRUN false'):
    try:
        pin.render(source, 'foundation', 'bootcrew-system', image)
    except ValueError:
        pass
    else:
        raise AssertionError('mutable or malformed parent accepted')
for bad in (source.replace('FROM bootcrew-system AS foundation', 'FROM changed AS foundation'), source+'\nFROM bootcrew-system AS foundation\n'):
    try:
        pin.render(bad, 'foundation', 'bootcrew-system', 'a'*64)
    except ValueError:
        pass
    else:
        raise AssertionError('missing/ambiguous stage accepted')
# Exercise the actual fatal ancestry check; labels cannot hide a rebuilt parent.
script = (root/'scripts/ci/candidate-build.sh').read_text()
function = 'verify_stage_ancestry() {'+script.split('verify_stage_ancestry() {',1)[1].split('\nrecord_stage_receipt()',1)[0]
for layers, expected in [(['a','b','c'],0), (['x','b','c'],1), (['a'],1), ([],1)]:
    command = 'sudo() { if [[ $5 == parent ]]; then printf "%s\\n" '\
        +repr(json.dumps(['a','b']))+'; else printf "%s\\n" '+repr(json.dumps(layers))+'; fi; };\n'\
        +function+'\nverify_stage_ancestry parent child fixture'
    result = subprocess.run(['bash','-eu','-c',command],capture_output=True,text=True)
    assert result.returncode == expected, (layers,result.stdout,result.stderr)
assert script.count('--file "${ARTIFACT_DIR}/Containerfile.') == 3
assert '--file "$candidate_file"' in script
print('PASS: stage parents bind immutable IDs, all other build logic stays byte-identical, divergent ancestry fails')
PY
