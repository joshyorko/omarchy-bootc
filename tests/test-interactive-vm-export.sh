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
 # Run the actual setup immediately before QEMU, then use a restrictive
 # writer to verify that opening existing files preserves readable ownership.
 out=Path(t)/'receipts';out.mkdir();pid=Path(t)/'qemu.pid'
 setup=script.split('# Keep runner ownership even when QEMU opens these files with a root umask.\n',1)[1].split('sudo -n qemu-system-x86_64',1)[0]
 subprocess.run(['bash','-eu','-c',setup],env=dict(os.environ,out=str(out),pidfile=str(pid)),check=True)
 for target in [out/'guest-serial.log',pid]:
  assert target.exists() and target.stat().st_uid==os.getuid()
  old=os.umask(0o077)
  try:
   with target.open('w') as f:f.write('runner-readable')
  finally:os.umask(old)
  assert target.read_text()=='runner-readable' and target.stat().st_uid==os.getuid()
print('PASS: workstation refusal and removal of reusable password from actual firstboot fixture; no VM proof claimed')
PY
