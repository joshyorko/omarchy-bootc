#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" "${1:-}" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import time

source=Path(sys.argv[1])/'scripts/ci/dagger-host-runtime.sh'
assert os.geteuid()!=0, 'Run this permission-boundary fixture as an ordinary user, never root'
if sys.argv[2]=='--hosted-root-setup':
    assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_OS')=='Linux', 'Real privileged setup is hosted CI only'
    assert 'ID=ubuntu' in Path('/etc/os-release').read_text(), 'Real setup requires the Ubuntu runner'
    with tempfile.TemporaryDirectory(prefix='omarchy-host-lock-',dir=os.environ['RUNNER_TEMP']) as temp:
        base=Path(temp);scripts=base/'scripts/ci';scripts.mkdir(parents=True)
        (scripts/'candidate-runtime.sh').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$2" >>"$PHASE_LOG"\n')
        env=dict(os.environ,CI_ARTIFACT_DIR=str(base/'receipts'),PHASE_LOG=str(base/'phases'))
        result=subprocess.run(['bash',str(source),str(base/'candidate')],cwd=base,env=env,capture_output=True,text=True,timeout=15)
        assert result.returncode==0,result.stderr
        lock=Path('/run/omarchy-bootc-runtime-locks/host-runtime.lock')
        assert lock.stat().st_uid==0 and lock.stat().st_mode & 0o777 == 0o644
        assert (base/'phases').read_text().splitlines()==['import','overlay','boot']
    print('PASS: actual Ubuntu runner UID opens the real root-owned host lock; no OCI/VM phase is executed')
    sys.exit(0)
assert not sys.argv[2], 'Unknown fixture mode'
with tempfile.TemporaryDirectory(prefix='codex-host-runtime-lock-',dir='/tmp') as temp:
    base=Path(temp);bin_dir=base/'bin';bin_dir.mkdir()
    protected=base/'rootful-containers';protected.mkdir()
    shared=base/'run';shared.mkdir()
    lock_root=shared/'omarchy-bootc-runtime-locks'
    scripts=base/'scripts/ci';scripts.mkdir(parents=True)
    # Substitute filesystem namespaces only, preserving the actual shell and
    # Linux flock. Rootful storage is genuinely unsearchable to this process.
    script=scripts/'dagger-host-runtime.sh'
    text=source.read_text().replace('/var/lib/containers/omarchy-runtime-locks',str(protected/'omarchy-runtime-locks')).replace('/run/omarchy-bootc-runtime-locks',str(lock_root))
    script.write_text(text)
    # Privileged setup is the sole unavoidable double on the control-plane host.
    # It can traverse the protected fixture namespace; the worker itself cannot.
    sudo=bin_dir/'sudo'
    sudo.write_text('''#!/usr/bin/env python3
import os,subprocess,sys
from pathlib import Path
args=sys.argv[1:];assert args.pop(0)=='-n'
blocked=Path(os.environ['PROTECTED_FIXTURE']);blocked.chmod(0o700)
try:
 if args[0]=='install':
  for flag in ['-o','-g']:
   if flag in args:
    index=args.index(flag);del args[index:index+2]
 if args[0]=='chmod' and args[-1].endswith('/host-runtime.lock'):
  # Root-owned 0644 is read-only to the runner. Enforce that same access on
  # this unprivileged fixture without changing any real ownership.
  args[1]='0444'
 result=subprocess.run(args)
finally:blocked.chmod(0)
sys.exit(result.returncode)
''');sudo.chmod(0o755)
    worker=scripts/'candidate-runtime.sh'
    worker.write_text('''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$2" >>"$PHASE_LOG"
if [[ $2 == import && ${HOLD_LOCK:-} == true ]]; then
 touch "$READY_FILE"
 while [[ ! -f $RELEASE_FILE ]]; do sleep 0.05; done
fi
''')
    env=dict(os.environ,PATH=str(bin_dir)+':'+os.environ['PATH'],GITHUB_ACTIONS='true',
             CI_ARTIFACT_DIR=str(base/'receipts'),PROTECTED_FIXTURE=str(protected),
             PHASE_LOG=str(base/'phases'),READY_FILE=str(base/'ready'),RELEASE_FILE=str(base/'release'))
    protected.chmod(0)
    first=None
    try:
        result=subprocess.run(['bash',str(script),str(base/'candidate')],cwd=base,env=env,capture_output=True,text=True,timeout=10)
        assert result.returncode==0, 'Runtime must acquire its host lock without opening the rootful store: '+result.stderr
        assert (base/'phases').read_text().splitlines()==['import','overlay','boot']
        # A root-created read-only lock file must remain usable without inode
        # replacement. A second actual worker must not enter any runtime phase.
        lock=lock_root/'host-runtime.lock';lock.chmod(0o444);inode=lock.stat().st_ino
        (base/'phases').unlink()
        holding=dict(env,HOLD_LOCK='true')
        first=subprocess.Popen(['bash',str(script),str(base/'candidate')],cwd=base,env=holding,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        deadline=time.monotonic()+8
        while not (base/'ready').exists() and first.poll() is None and time.monotonic()<deadline:time.sleep(0.02)
        assert (base/'ready').exists(), first.communicate(timeout=1)
        second=subprocess.run(['bash',str(script),str(base/'candidate')],cwd=base,env=env,capture_output=True,text=True,timeout=5)
        assert second.returncode!=0 and (base/'phases').read_text().splitlines()==['import'],second.stderr
        assert lock.stat().st_ino==inode, 'Lock setup replaced a held inode'
        (base/'release').touch();out,err=first.communicate(timeout=8)
        assert first.returncode==0,err
        assert (base/'phases').read_text().splitlines()==['import','overlay','boot']
    finally:
        if first is not None and first.poll() is None:
            (base/'release').touch();first.terminate();first.communicate(timeout=5)
        protected.chmod(0o700)
print('PASS: real non-root permission boundary, readable shared lock, concurrent-worker refusal and stable lock inode (no root, OCI or VM execution)')
PY
