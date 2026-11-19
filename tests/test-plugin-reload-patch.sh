#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "$root/build/patch-quattro-plugin-reload.py" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

script = sys.argv[1]
original = b'''import Quickshell
Timer {
    id: localPluginReloadTimer
    interval: 150
    onTriggered: shell.reloadPlugins()
}
function rescanPlugins() { shell.reloadPlugins() }
'''
with tempfile.TemporaryDirectory(prefix='plugin-reload-patch-') as tmp:
    qml, receipt = Path(tmp)/'shell.qml', Path(tmp)/'receipt.json'
    qml.write_bytes(original)
    subprocess.run([sys.executable, script, str(qml), str(receipt)], check=True)
    expected = original.replace(b'onTriggered: shell.reloadPlugins()', b'onTriggered: Quickshell.reload(false)')
    assert qml.read_bytes() == expected
    data = json.loads(receipt.read_text())
    assert data['before_sha256'] == hashlib.sha256(original).hexdigest()
    assert data['after_sha256'] == hashlib.sha256(expected).hexdigest()
    for drift in (b'changed upstream timer', original + original):
        qml.write_bytes(drift)
        receipt.unlink()
        result = subprocess.run([sys.executable, script, str(qml), str(receipt)], capture_output=True)
        assert result.returncode != 0 and qml.read_bytes() == drift and not receipt.exists()
        receipt.write_text('fixture')
    clone = Path(tmp)/'clone.sh'
    clone.write_text('new_id="${USER:-$(id -un)}.${source_id#omarchy.}"\nprintf "%s" "$new_id"\n')
    subprocess.run([sys.executable, script, str(clone), str(receipt), 'clone'], check=True)
    for user, source, expected in [('omarchy', 'omarchy.clock', 'local.omarchy.clock'),
                                    ('alice', 'omarchy.clock', 'alice.clock'),
                                    ('omarchy', 'omarchy.audio', 'local.omarchy.audio')]:
        result = subprocess.run(['bash', '-euc', 'USER="$1"; source_id="$2"; source "$3"',
                                 'fixture', user, source, str(clone)], capture_output=True, text=True, check=True)
        assert result.stdout == expected
        assert result.stdout != source
        assert not result.stdout.startswith('omarchy.'), 'third-party clone uses reserved namespace'
print('PASS: targeted plugin reload patch, provenance hashes, and drift refusal')
PY
