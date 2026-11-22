#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
status=0
env -u GITHUB_ACTIONS bash "$root/scripts/ci/export-interactive-vm.sh" >/dev/null 2>&1 || status=$?
[[ $status == 2 ]] || { echo 'Workstation VM export guard failed' >&2; exit 1; }
python3 -B - "$root" <<'PY'
from pathlib import Path
import sys,tempfile,subprocess,os
root=Path(sys.argv[1]);script=(root/'scripts/ci/export-interactive-vm.sh').read_text()
# Execute the actual password-removal transformation; never create a guest or
# invoke Podman, sudo or QEMU locally.
code=script.split('<<\'PY\'\n',1)[1].split('\nPY\n',1)[0]
with tempfile.TemporaryDirectory(prefix='codex-interactive-user-',dir='/tmp') as t:
 p=Path(t)/'firstboot.sh';p.write_text((root/'build/acceptance-firstboot.sh').read_text())
 subprocess.run(['python3','-B','-c',code,str(p)],check=True)
 result=p.read_text()
 assert 'chpasswd' not in result and 'passwd -l omarchy' in result
 assert '/usr/bin/omarchy-provision-user --first-install' in result
print('PASS: workstation refusal and removal of reusable password from actual firstboot fixture; no VM proof claimed')
PY
