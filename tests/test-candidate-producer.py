#!/usr/bin/env python3
"""Producer metadata boundary tests; never a candidate/guest acceptance mock."""
import copy
import importlib.util
from pathlib import Path

path = Path(__file__).resolve().parents[1] / 'scripts/ci/verify-candidate-producer.py'
spec = importlib.util.spec_from_file_location('producer', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
head = 'a' * 40
run = {'id': 12, 'head_sha': head, 'repository': {'id': 99, 'full_name': module.REPOSITORY},
       'head_repository': {'full_name': module.REPOSITORY}, 'path': '.github/workflows/candidate.yml',
       'workflow_id': 7, 'run_attempt': 1}
workflow = {'id': 7, 'path': run['path']}
jobs = [{'id': 11, 'run_id': 12, 'head_sha': head, 'name': 'Build exact-head candidate',
         'conclusion': 'success', 'started_at': '2026-11-19T12:00:00Z',
         'completed_at': '2026-11-19T12:02:00Z'}]
artifacts = [{'id': 13, 'name': 'omarchy-bootc-candidate-' + head, 'size_in_bytes': 123,
              'expired': False, 'digest': 'sha256:' + 'b' * 64, 'created_at': '2026-11-19T12:01:00Z',
              'workflow_run': {'id': 12, 'head_sha': head, 'repository_id': 99, 'head_repository_id': 99}}]
assert module.validate(run, workflow, jobs, artifacts, 12, head)['artifact_id'] == 13

def refused(r=run, w=workflow, j=jobs, a=artifacts):
    try:
        module.validate(r, w, j, a, 12, head)
    except (ValueError, KeyError, TypeError):
        return
    raise AssertionError('invalid producer metadata was accepted')

for key, value in [('head_sha', 'c' * 40), ('id', 14), ('path', '.github/workflows/unknown.yml')]:
    changed = copy.deepcopy(run)
    changed[key] = value
    refused(r=changed)
changed = copy.deepcopy(run)
changed['head_repository']['full_name'] = 'other/fork'
refused(r=changed)
refused(w={'id': 8, 'path': workflow['path']})
for key, value in [('conclusion', 'failure'), ('conclusion', 'skipped'), ('run_id', 14), ('head_sha', 'd' * 40)]:
    changed = copy.deepcopy(jobs)
    changed[0][key] = value
    refused(j=changed)
refused(j=[])
refused(j=jobs + jobs)
for key, value in [('expired', True), ('size_in_bytes', 0), ('digest', ''), ('id', 0),
                   ('created_at', '2026-11-19T11:59:00Z')]:
    changed = copy.deepcopy(artifacts)
    changed[0][key] = value
    refused(a=changed)
for key, value in [('id', 14), ('head_sha', 'd' * 40), ('head_repository_id', 100)]:
    changed = copy.deepcopy(artifacts)
    changed[0]['workflow_run'][key] = value
    refused(a=changed)
refused(a=[])
refused(a=artifacts + artifacts)
print('PASS: Actions producer, workflow, head, successful job and immutable artifact boundaries')
