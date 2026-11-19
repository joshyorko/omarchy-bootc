#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import sys
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
candidate=(root/'.github/workflows/candidate.yml').read_text()
runtime=candidate.split('\n  runtime:',1)[1].split('\n  runtime-status:',1)[0]
assert 'statuses: write' not in runtime
assert 'needs: [candidate, runtime-pending]' in runtime
assert runtime.index('verify-candidate-producer.py') < runtime.index('actions/download-artifact') < runtime.index('Verify archive identity and import candidate')
assert 'artifact-ids: ${{ steps.candidate_producer.outputs.artifact_id }}' in runtime
print('PASS: accepted-manifest promotion/sign/channel order and least-privilege job boundaries')
PY
