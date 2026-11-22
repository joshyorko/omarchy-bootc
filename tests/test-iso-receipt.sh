#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import hashlib,json,subprocess,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='codex-iso-receipt-',dir='/tmp') as temp:
 p=Path(temp);payload=p/'fixture.iso';payload.write_bytes(b'receipt integrity fixture, not a bootable ISO')
 builder='a'*40;source='b'*40;image='ghcr.io/joshyorko/omarchy-bootc@sha256:'+'c'*64
 receipt=dict(schema='omarchy-bootc.installer-iso/v1',iso_filename=payload.name,iso_sha256=hashlib.sha256(payload.read_bytes()).hexdigest(),builder_source_sha=builder,install_source_sha=source,install_image_ref=image,tracking_image_ref='ghcr.io/joshyorko/omarchy-bootc:testing',run_id='123')
 def run(value,ok):
  (p/'iso.receipt.json').write_text(json.dumps(value))
  r=subprocess.run(['bash',str(root/'scripts/ci/verify-iso-receipt.sh'),str(p),builder,source,image,'123'],capture_output=True,text=True)
  assert (r.returncode==0)==ok,(value,r.stderr)
 run(receipt,True)
 for key,value in [('builder_source_sha','d'*40),('install_source_sha','d'*40),('install_image_ref',image.replace('c'*64,'d'*64)),('run_id','124'),('iso_sha256','0'*64),('iso_filename','../fixture.iso'),('tracking_image_ref','ghcr.io/joshyorko/omarchy-bootc:stable')]:
  run(dict(receipt,**{key:value}),False)
 payload.write_bytes(b'tampered');run(receipt,False)
 (p/'iso.receipt.json').unlink()
 r=subprocess.run(['bash',str(root/'scripts/ci/verify-iso-receipt.sh'),str(p),builder,source,image,'123'],capture_output=True)
 assert r.returncode!=0
print('PASS: ISO receipt separates builder/payload identities and rejects wrong source, producer, digest, path, stream, missing receipt and changed bytes; no ISO boot claimed')
PY
