#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import copy,hashlib,importlib.util,io,json,sys,tarfile,tempfile
from pathlib import Path
p=Path(sys.argv[1])/'scripts/ci/verify-candidate-archive.py'
spec=importlib.util.spec_from_file_location('archive',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
head='a'*40
with tempfile.TemporaryDirectory() as directory:
 root=Path(directory);archive=root/'candidate.oci.tar';receipt=root/'candidate.receipt.json'
 config=json.dumps({'architecture':'amd64','os':'linux','config':{'Labels':{'org.opencontainers.image.revision':head}},'rootfs':{'type':'layers','diff_ids':[]}}).encode()
 config_digest=m.digest(config)
 manifest=json.dumps({'schemaVersion':2,'mediaType':'application/vnd.oci.image.manifest.v1+json','config':{'digest':config_digest,'mediaType':'application/vnd.oci.image.config.v1+json','size':len(config)},'layers':[]}).encode()
 manifest_digest=m.digest(manifest)
 members={'index.json':json.dumps({'schemaVersion':2,'manifests':[{'digest':manifest_digest}]}).encode(),'blobs/sha256/'+manifest_digest[7:]:manifest,'blobs/sha256/'+config_digest[7:]:config}
 with tarfile.open(archive,'w') as output:
  for name,data in members.items():
   info=tarfile.TarInfo(name);info.size=len(data);output.addfile(info,io.BytesIO(data))
 baseline={'source_head':head,'archive':archive.name,'image_id':config_digest,'manifest_digest':manifest_digest,'archive_sha256':m.digest(archive.read_bytes())}
 receipt.write_text(json.dumps(baseline))
 assert m.verify(receipt,archive,head)['config_digest']==config_digest
 # A pre-existing unrelated image in a warm store cannot satisfy this binding.
 for key,value in [('image_id','sha256:'+'b'*64),('manifest_digest','sha256:'+'b'*64),('archive_sha256','sha256:'+'b'*64),('source_head','b'*40),('archive','../candidate.oci.tar')]:
  changed=copy.deepcopy(baseline);changed[key]=value;receipt.write_text(json.dumps(changed))
  try:m.verify(receipt,archive,head)
  except ValueError:pass
  else:raise AssertionError(key+' mismatch accepted')
 receipt.write_text(json.dumps(baseline))
 accepted=root/'accepted.json'
 accepted.write_text(json.dumps({'source_sha':head,'acceptance':{'status':'passed','overlay_scope':'disposable-test-fixture-only'},'candidate':{'oci_manifest_digest':manifest_digest,'archive_sha256':baseline['archive_sha256'],'local_image_id':config_digest}}))
 bin_dir=root/'bin';bin_dir.mkdir()
 skopeo=bin_dir/'skopeo'
 skopeo.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"$COPY_CALLS"\nif [[ $1 == inspect ]]; then cat "$RAW_MANIFEST"; fi\n')
 skopeo.chmod(0o755)
 raw=root/'raw.json';raw.write_bytes(manifest)
 import os,subprocess
 env=dict(os.environ,PATH=str(bin_dir)+':'+os.environ['PATH'],COPY_CALLS=str(root/'calls'),RAW_MANIFEST=str(raw),GITHUB_OUTPUT=str(root/'outputs'))
 command=['bash',str(p.with_name('promote-accepted-image.sh')),str(root),str(accepted),'ghcr.io/joshyorko/omarchy-bootc',head,'accepted-'+head+'-12-1']
 result=subprocess.run(command,env=env,capture_output=True,text=True)
 assert result.returncode==0,result.stderr
 assert result.stdout.strip()==manifest_digest
 assert '--preserve-digests' in (root/'calls').read_text()
 assert ':testing' not in (root/'calls').read_text()
 (root/'outputs').unlink()
 # Same config, different schema/media-type manifest must not be signed/promoted.
 converted=json.loads(manifest);converted['mediaType']='application/vnd.docker.distribution.manifest.v2+json'
 raw.write_text(json.dumps(converted))
 result=subprocess.run(command,env=env,capture_output=True,text=True)
 assert result.returncode!=0,'registry manifest conversion accepted'
 assert not (root/'outputs').exists(),'mismatch emitted a publishable digest'
print('PASS: OCI archive bytes, manifest, config/image ID, platform and source binding')
PY
