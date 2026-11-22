#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import importlib.util
import functools
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request

root=Path(sys.argv[1])
script=root/'scripts/ci/iso-install-acceptance.sh'
# Launcher failures previously vanished before reaching privileged serial.
# Exercise the actual bounded log receiver and its file/path error boundary.
receiver=root/'scripts/ci/iso-fixture-server.py'
assert receiver.exists(), 'launcher failures need an unprivileged diagnostic channel'
spec=importlib.util.spec_from_file_location('fixture_http',receiver)
fixture_http=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture_http)
with tempfile.TemporaryDirectory(prefix='codex-iso-http-',dir='/tmp') as temp:
 base=Path(temp);web=base/'web';web.mkdir();(web/'start.sh').write_text('fixture script')
 out=base/'out';out.mkdir()
 handler=functools.partial(fixture_http.Handler,directory=str(web),evidence=out)
 with http.server.ThreadingHTTPServer(('127.0.0.1',0),handler) as server:
  thread=threading.Thread(target=server.serve_forever);thread.start()
  try:
   url=f'http://127.0.0.1:{server.server_port}'
   assert urllib.request.urlopen(url+'/start.sh',timeout=5).read()==b'fixture script'
   for path,data,status in [('/launcher-log',b'sudo: a password is required\n',204),('/../other',b'bad',404),('/launcher-log',b'x'*(256*1024+1),413)]:
    request=urllib.request.Request(url+path,data=data,method='POST')
    try:response=urllib.request.urlopen(request,timeout=5);actual=response.status;response.close()
    except urllib.error.HTTPError as error:actual=error.code
    assert actual==status,(path,actual,status)
   assert (out/'live-launcher.log').read_bytes()==b'sudo: a password is required\n'
   for data in (b'OMARCHY_LIVE_LAUNCHER_EXIT=1\n', b'an older in-flight snapshot\n'):
    response=urllib.request.urlopen(urllib.request.Request(url+'/launcher-log',data=data,method='POST'),timeout=5)
    assert response.status==204;response.close()
   assert b'OMARCHY_LIVE_LAUNCHER_EXIT=1\n' in (out/'live-launcher.log').read_bytes()
   malformed=urllib.request.Request(url+'/launcher-log',data=b'',method='POST',headers={'Content-Length':'invalid'})
   try:urllib.request.urlopen(malformed,timeout=5)
   except urllib.error.HTTPError as error:assert error.code==400
   else:raise AssertionError('invalid log size accepted')
   assert sorted(p.name for p in out.iterdir())==['live-launcher.log']
  finally:server.shutdown();thread.join(timeout=5)
# Exercise real command encoding before QMP transport. The previous harness
# supplied inst.ks but never sent any launcher command to the live desktop.
launcher=root/'scripts/ci/qmp-run-command.py'
assert launcher.exists(), 'live desktop needs an explicit installer launcher'
spec=importlib.util.spec_from_file_location('qmp_command',launcher)
qmp_command=importlib.util.module_from_spec(spec);spec.loader.exec_module(qmp_command)
command="sh -c 'curl -fsS http://10.0.2.2:18763/start.sh|bash'"
keys=qmp_command.command_keys(command)
assert keys[0]==['alt','f2'] and keys[-1]==['ret']
# Independently decode the actual QEMU keycodes and modifiers back to the
# complete shell command, including quotes, uppercase S, colon and pipe.
plain={'spc':' ','minus':'-','slash':'/','dot':'.','apostrophe':"'",'semicolon':';','backslash':'\\'}
shift={'semicolon':':','backslash':'|'}
decoded=''
for chord in keys[1:-1]:
 key=chord[-1]
 if chord[0]=='shift':decoded+=shift.get(key,key.upper())
 else:decoded+=plain.get(key,key)
assert decoded==command,(decoded,command)
for invalid in ('', 'echo\nreboot', 'é', 'x'*513):
 try:qmp_command.command_keys(invalid)
 except ValueError:pass
 else:raise AssertionError('invalid launcher input accepted')
env=dict(os.environ);env.pop('GITHUB_ACTIONS',None)
refused=subprocess.run(['bash',str(script)],env=env,capture_output=True,text=True,timeout=5)
assert refused.returncode==2 and 'GitHub-hosted CI only' in refused.stderr

spec=importlib.util.spec_from_file_location('qmp_login',root/'scripts/ci/qmp-login.py')
qmp=importlib.util.module_from_spec(spec);spec.loader.exec_module(qmp)
with tempfile.TemporaryDirectory(prefix='codex-iso-contract-',dir='/tmp') as temp:
 base=Path(temp);path=base/'qmp.sock';requests=[];errors=[];launcher_requests=[]
 with socket.socket(socket.AF_UNIX) as server:
  server.bind(str(path));server.listen(1);server.settimeout(10)
  def serve():
   try:
    for attempt in range(3):
     connection,_=server.accept()
     with connection:
      stream=connection.makefile('rwb')
      stream.write(b'{"QMP":{}}\n');stream.flush()
      for line in stream:
       value=json.loads(line)
       (requests if attempt==0 else launcher_requests).append(value)
       reply={'error':{'class':'GenericError','desc':'fixture rejected key'}} if attempt==2 and value['execute']=='send-key' else {'return':{}}
       stream.write((json.dumps(dict(reply,id=value['id']))+'\n').encode());stream.flush()
   except Exception as error:errors.append(error)
  thread=threading.Thread(target=serve);thread.start()
  qmp.login(path,'abc123')
  qmp_command.run_command(path,command)
  try:qmp_command.run_command(path,'a')
  except ValueError as error:assert 'fixture rejected key' in str(error)
  else:raise AssertionError('QMP rejection did not fail the launcher')
  thread.join(timeout=10)
  assert not thread.is_alive() and not errors
 assert requests[0]['execute']=='qmp_capabilities'
 sent=launcher_requests[:len(keys)+1]
 assert sent[0]['execute']=='qmp_capabilities'
 assert [[key['data'] for key in r['arguments']['keys']] for r in sent[1:]]==keys
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
assert 'screenshots/*.json' in workflow and 'iso-install/*.md' in workflow
# Execute the actual pre-download metadata boundary, substituting only GitHub
# transport. Reject foreign/failed producers and expired/ambiguous artifacts.
block=workflow.split('      - name: Verify trusted ISO producer before downloading\n',1)[1].split('      - name: Prepare hosted KVM tools\n',1)[0]
producer='\n'.join(line[10:] for line in block.split('        run: |\n',1)[1].splitlines())
for bad in ('', 'different-builder', 'malformed-head', 'branch', 'workflow', 'run-failed', 'job-skipped', 'expired', 'duplicate'):
 with tempfile.TemporaryDirectory(prefix='codex-iso-producer-',dir='/tmp') as temp:
  base=Path(temp);bin_dir=base/'bin';bin_dir.mkdir()
  run={'head_sha':'bad' if bad=='malformed-head' else ('b' if bad=='different-builder' else 'a')*40,'head_branch':'foreign' if bad=='branch' else 'main','conclusion':'failure' if bad=='run-failed' else 'success','path':'.github/workflows/candidate.yml' if bad=='workflow' else '.github/workflows/build.yml'}
  jobs={'jobs':[{'name':'Build installer ISO / Build installer ISO','conclusion':'skipped' if bad=='job-skipped' else 'success'}]}
  item={'id':99,'name':'omarchy-bootc-testing-installer-x86_64','expired':bad=='expired'}
  artifacts={'artifacts':[item,item] if bad=='duplicate' else [item]}
  for name,value in [('run',run),('jobs',jobs),('artifacts',artifacts)]:
   (base/(name+'.json')).write_text(json.dumps(value))
  gh=bin_dir/'gh';gh.write_text('#!/usr/bin/env bash\ncase "$2" in\n */artifacts*) cat "$FIXTURE_DATA/artifacts.json";;\n */jobs*) cat "$FIXTURE_DATA/jobs.json";;\n *) cat "$FIXTURE_DATA/run.json";;\nesac\n');gh.chmod(0o755)
  env=dict(os.environ,PATH=str(bin_dir)+':'+os.environ['PATH'],FIXTURE_DATA=temp,RUNNER_TEMP=temp,ISO_RUN='42',ISO_SOURCE='a'*40,GITHUB_REPOSITORY='joshyorko/omarchy-bootc',GITHUB_OUTPUT=str(base/'output'))
  result=subprocess.run(['bash','-c',producer],env=env,capture_output=True,text=True,timeout=10)
  accepted=bad in ('','different-builder')
  assert (result.returncode==0)==accepted,(bad,result.stderr)
  if accepted:assert (base/'output').read_text()=='artifact_id=99\n'
  else:assert not (base/'output').exists()
# A newer reviewed builder is permitted only with the separate payload/run/hash
# receipt gate, whose negative cases live in test-iso-receipt.sh.
assert workflow.index('bash scripts/ci/verify-iso-receipt.sh') < workflow.index('90m bash scripts/ci/iso-install-acceptance.sh')
text=script.read_text()
# The unmodified product requires a sudo password. Exercise the actual status
# command with only SSH transport substituted; never add NOPASSWD to the image.
line=next(line for line in text.splitlines() if line.startswith("guest '") and 'installed-bootc-status.json' in line)
with tempfile.TemporaryDirectory(prefix='codex-iso-status-',dir='/tmp') as temp:
 env=dict(os.environ,CI_ARTIFACT_DIR=temp,password='disposablefixture',EXPECTED_PASSWORD='disposablefixture')
 command='''guest() {
   [[ $# == 1 && $1 == 'sudo -S -p "" -- /usr/libexec/omarchy-bootc-status' ]] || return 2
   local supplied; IFS= read -r supplied
   [[ $supplied == "$EXPECTED_PASSWORD" ]] || return 3
   printf '{"status":"fixture"}\\n'
 }
 '''+line
 result=subprocess.run(['bash','-eu','-c',command],env=env,capture_output=True,text=True,timeout=5)
 assert result.returncode==0,result.stderr
 assert json.loads((Path(temp)/'installed-bootc-status.json').read_text())=={'status':'fixture'}
assert 'NOPASSWD' not in text
assert 'bootc install' not in '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
assert text.index('qemu-img create') < text.index('ostreecontainer --url=')
assert 'user --name=omarchyci' in text and 'reboot --eject' in text
assert 'status.booted.image.imageDigest == $digest' in text and '.status.booted.composefs != null' in text
assert 'installed-greeter' in text and 'installed-desktop' in text and 'qmp-login.py' in text
assert "installer-observed-%03d" in text and 'installer-last-observed' not in text
assert 'record-screenshot-evidence.py' in text and 'ISO_SHA256' in text
assert text.index('qmp-login.py') < text.index('installed-desktop') < text.index('iso-install.receipt.json')
print('PASS: no workstation disk operations; exact one-shot QMP login keys; artifact-only signed ISO wiring and installed guest gates (not a VM pass)')
PY
