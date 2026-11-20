#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

root=Path(sys.argv[1])
script=root/'scripts/ci/iso-install-acceptance.sh'
env=dict(os.environ);env.pop('GITHUB_ACTIONS',None)
refused=subprocess.run(['bash',str(script)],env=env,capture_output=True,text=True,timeout=5)
assert refused.returncode==2 and 'GitHub-hosted CI only' in refused.stderr

spec=importlib.util.spec_from_file_location('qmp_login',root/'scripts/ci/qmp-login.py')
qmp=importlib.util.module_from_spec(spec);spec.loader.exec_module(qmp)
with tempfile.TemporaryDirectory(prefix='codex-iso-contract-',dir='/tmp') as temp:
 base=Path(temp);path=base/'qmp.sock';requests=[];errors=[]
 with socket.socket(socket.AF_UNIX) as server:
  server.bind(str(path));server.listen(1);server.settimeout(10)
  def serve():
   try:
    connection,_=server.accept()
    with connection:
     stream=connection.makefile('rwb')
     stream.write(b'{"QMP":{}}\n');stream.flush()
     for line in stream:
      value=json.loads(line);requests.append(value)
      stream.write((json.dumps({'return':{},'id':value['id']})+'\n').encode());stream.flush()
   except Exception as error:errors.append(error)
  thread=threading.Thread(target=serve);thread.start()
  qmp.login(path,'abc123')
  thread.join(timeout=10)
  assert not thread.is_alive() and not errors
 assert requests[0]['execute']=='qmp_capabilities'
 assert [r['arguments']['keys'][0]['data'] for r in requests[1:]]==list('abc123')+['ret']
 assert all(r['arguments']['hold-time']==60 for r in requests[1:])
 for invalid in ('', 'bad;key', 'PassWord', '\n'):
  try:qmp.login(path,invalid)
  except ValueError:pass
  else:raise AssertionError('unsafe key sequence accepted')

workflow=(root/'.github/workflows/build-iso.yml').read_text()
assert "if: inputs.acceptance_artifact_run_id == ''" in workflow
assert 'artifact-ids: ${{ steps.iso_producer.outputs.artifact_id }}' in workflow
assert workflow.index('Verify exact signed image and source') < workflow.index('actions/download-artifact')
assert 'sha256sum -c' in workflow and '90m bash scripts/ci/iso-install-acceptance.sh' in workflow
assert 'packages: write' not in workflow and 'id-token: write' not in workflow
# Execute the actual pre-download metadata boundary, substituting only GitHub
# transport. Reject foreign/failed producers and expired/ambiguous artifacts.
block=workflow.split('      - name: Verify trusted ISO producer before downloading\n',1)[1].split('      - name: Prepare hosted KVM tools\n',1)[0]
producer='\n'.join(line[10:] for line in block.split('        run: |\n',1)[1].splitlines())
for bad in ('', 'source', 'workflow', 'run-failed', 'job-skipped', 'expired', 'duplicate'):
 with tempfile.TemporaryDirectory(prefix='codex-iso-producer-',dir='/tmp') as temp:
  base=Path(temp);bin_dir=base/'bin';bin_dir.mkdir()
  run={'head_sha':('b' if bad=='source' else 'a')*40,'head_branch':'main','conclusion':'failure' if bad=='run-failed' else 'success','path':'.github/workflows/candidate.yml' if bad=='workflow' else '.github/workflows/build.yml'}
  jobs={'jobs':[{'name':'Build installer ISO / Build installer ISO','conclusion':'skipped' if bad=='job-skipped' else 'success'}]}
  item={'id':99,'name':'omarchy-bootc-testing-installer-x86_64','expired':bad=='expired'}
  artifacts={'artifacts':[item,item] if bad=='duplicate' else [item]}
  for name,value in [('run',run),('jobs',jobs),('artifacts',artifacts)]:
   (base/(name+'.json')).write_text(json.dumps(value))
  gh=bin_dir/'gh';gh.write_text('#!/usr/bin/env bash\ncase "$2" in\n */artifacts*) cat "$FIXTURE_DATA/artifacts.json";;\n */jobs*) cat "$FIXTURE_DATA/jobs.json";;\n *) cat "$FIXTURE_DATA/run.json";;\nesac\n');gh.chmod(0o755)
  env=dict(os.environ,PATH=str(bin_dir)+':'+os.environ['PATH'],FIXTURE_DATA=temp,RUNNER_TEMP=temp,ISO_RUN='42',ISO_SOURCE='a'*40,GITHUB_REPOSITORY='joshyorko/omarchy-bootc',GITHUB_OUTPUT=str(base/'output'))
  result=subprocess.run(['bash','-c',producer],env=env,capture_output=True,text=True,timeout=10)
  assert (result.returncode==0)==(not bad),(bad,result.stderr)
  if not bad:assert (base/'output').read_text()=='artifact_id=99\n'
  else:assert not (base/'output').exists()
text=script.read_text()
assert 'bootc install' not in '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
assert text.index('qemu-img create') < text.index('ostreecontainer --url=')
assert 'user --name=omarchyci' in text and 'reboot --eject' in text
assert 'status.booted.image.imageDigest == $digest' in text and '.status.booted.composefs != null' in text
assert 'installed-greeter' in text and 'installed-desktop' in text and 'qmp-login.py' in text
assert text.index('qmp-login.py') < text.index('installed-desktop') < text.index('iso-install.receipt.json')
print('PASS: no workstation disk operations; exact one-shot QMP login keys; artifact-only signed ISO wiring and installed guest gates (not a VM pass)')
PY
