#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import json,os,subprocess,sys,tempfile
from pathlib import Path
script=Path(sys.argv[1])/'scripts/ci/watch-main-result.sh'
for status,conclusion,source,watch_rc,expected in [('completed','success','a'*40,0,'success'),('completed','failure','a'*40,1,'failure'),('queued',None,'a'*40,1,'error'),('completed','success','b'*40,0,'error')]:
 with tempfile.TemporaryDirectory(prefix='codex-main-observer-test-',dir='/tmp') as directory:
  root=Path(directory);bin_dir=root/'bin';bin_dir.mkdir()
  (root/'run.json').write_text(json.dumps({'head_sha':source,'status':status,'conclusion':conclusion}))
  gh=bin_dir/'gh'
  gh.write_text('''#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == run ]]; then exit "$WATCH_RC"; fi
if [[ $2 == *git/ref/heads/* ]]; then printf '%s\\n' "$CURRENT_HEAD"; exit; fi
if [[ $2 == --method ]]; then printf '%s\\n' "$*" >>"$POST_LOG"; else cat "$RUN_FIXTURE"; fi
''');gh.chmod(0o755)
  env=dict(os.environ,PATH=str(bin_dir)+':'+os.environ['PATH'],WATCH_RC=str(watch_rc),POST_LOG=str(root/'posts'),RUN_FIXTURE=str(root/'run.json'))
  result=subprocess.run(['bash',str(script),'42','a'*40,'c'*40],env=env,capture_output=True,text=True,timeout=10)
  lines=(root/'posts').read_text().splitlines()
  assert len(lines)==2 and 'state=pending' in lines[0] and 'state='+expected in lines[1],lines
  assert 'statuses/'+'c'*40 in lines[1]
  assert (result.returncode==0)==(expected=='success')
  (root/'posts').unlink()
  env['CURRENT_HEAD']='d'*40
  result=subprocess.run(['bash',str(script),'42','a'*40,'c'*40,'test/installer'],env=env,capture_output=True,text=True,timeout=10)
  lines=(root/'posts').read_text().splitlines()
  assert len(lines)==2 and all('statuses/'+'d'*40 in line for line in lines)
  assert 'state='+expected in lines[1] and (result.returncode==0)==(expected=='success')
print('PASS: main observer posts one verified terminal status; failures, incomplete run and wrong source never certify success')
PY
