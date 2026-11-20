#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
root=Path(sys.argv[1])
workflow=(root/'.github/workflows/build.yml').read_text()
build=workflow.split('\n  build_push:',1)[1].split('\n  publish:',1)[0]
publisher=workflow.split('\n  publish:',1)[1].split('\n  build_installer_iso:',1)[0]
assert 'packages: write' not in build and 'id-token: write' not in build
assert 'packages: write' in publisher and 'id-token: write' in publisher
assert 'redhat-actions/push-to-registry' not in workflow
assert 'artifact-ids: ${{ needs.build_push.outputs.accepted_artifact_id }}' in publisher
assert publisher.index('promote-accepted-image.sh') < publisher.index('cosign sign --yes') < publisher.index('update-accepted-channels.sh')
assert 'steps.promote.outputs.digest' in publisher
assert 'cosign-release: v2.6.0' in publisher
assert 'DEFAULT_TAG: "testing"' in workflow
assert 'redhat-actions/buildah-build' not in workflow and 'podman save' not in build
assert 'candidate-build.sh build' in build and 'dagger-host-runtime.sh' in build
assert build.index('candidate-build.sh preflight') < build.index('candidate-build.sh foundation')
# Execute main's actual receipt handoff. The downstream host boundary is doubled;
# real OCI parsing and prefixed/bare Podman comparison are exercised separately
# by test-candidate-archive.sh. No image is built or exported in this fixture.
block=build.split('      - name: Accept the exact publishable image through a disposable overlay\n',1)[1].split('      - name: Upload VM acceptance artifacts\n',1)[0]
script='\n'.join(line[10:] for line in block.split('        run: |\n',1)[1].splitlines())
for receipt_id in ('b'*64,'sha256:'+'b'*64):
 for wrong_head,wrong_acceptance in ((False,False),(True,False),(False,True)):
  with tempfile.TemporaryDirectory() as temp:
   fixture=Path(temp);candidate=fixture/'publish-candidate';candidate.mkdir()
   helper=fixture/'scripts/ci/dagger-host-runtime.sh';helper.parent.mkdir(parents=True)
   helper.write_text('''#!/usr/bin/env bash
set -euo pipefail
touch "$HOST_CALLED"
mkdir -p "$CI_ARTIFACT_DIR"
jq --arg digest "$ACCEPTED_DIGEST" '{candidate:{oci_manifest_digest:$digest},acceptance:{status:"passed"}}' "$1/candidate.receipt.json" >"$CI_ARTIFACT_DIR/accepted-candidate.receipt.json"
''')
   digest='sha256:'+'c'*64
   original=json.dumps({'source_head':('d' if wrong_head else 'a')*40,'image_id':receipt_id,'manifest_digest':digest,'archive':'preserved.oci.tar','archive_sha256':'sha256:'+'e'*64})
   (candidate/'exported.receipt.json').write_text(original)
   env=dict(os.environ,RUNNER_TEMP=temp,CI_ARTIFACT_DIR=str(fixture/'receipts'),GITHUB_SHA='a'*40,GITHUB_OUTPUT=str(fixture/'output'),HOST_CALLED=str(fixture/'host-called'),ACCEPTED_DIGEST=('sha256:'+'f'*64) if wrong_acceptance else digest)
   result=subprocess.run(['bash','-c',script],cwd=fixture,env=env,capture_output=True,text=True,timeout=10)
   assert (result.returncode==0)==(not wrong_head and not wrong_acceptance),(result.returncode,result.stderr)
   if wrong_head:assert not (fixture/'host-called').exists()
   else:assert (candidate/'candidate.receipt.json').read_text()==original
   if result.returncode==0:assert (fixture/'output').read_text()==f'digest={digest}\n'
   else:assert not (fixture/'output').exists()
   assert not list(candidate.glob('*.oci.tar')), 'handoff unexpectedly exported an image'
candidate=(root/'.github/workflows/candidate.yml').read_text()
runtime=candidate.split('\n  runtime:',1)[1].split('\n  runtime-status:',1)[0]
assert 'statuses: write' not in runtime
assert 'needs: [candidate, runtime-pending]' in runtime
assert runtime.index('verify-candidate-producer.py') < runtime.index('actions/download-artifact') < runtime.index('Verify archive identity and import candidate')
assert 'artifact-ids: ${{ steps.candidate_producer.outputs.artifact_id }}' in runtime
print('PASS: shared staged main build, exact receipt handoff, source/digest refusal, testing-only default and least-privilege promotion/sign order')
PY
