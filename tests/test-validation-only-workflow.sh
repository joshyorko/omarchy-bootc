#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import ast
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
workflow = (root/'.github/workflows/candidate.yml').read_text()
jobs = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', workflow.split('\njobs:\n', 1)[1], re.M | re.S))
conditions = {name: re.search(r'^    if: \$\{\{ (.*?) \}\}', body, re.M).group(1) for name, body in jobs.items()}

def enabled(name, validation, run_id='', result='skipped'):
    expression = conditions[name].replace('always()', 'True')
    values = {'inputs.validation_only': validation, 'inputs.candidate_run_id': run_id,
              'needs.candidate.result': result, 'github.event_name': 'workflow_dispatch',
              'github.event.pull_request.head.repo.full_name': 'joshyorko/omarchy-bootc',
              'github.repository': 'joshyorko/omarchy-bootc'}
    for key in sorted(values, key=len, reverse=True):
        expression = expression.replace(key, repr(values[key]))
    expression = re.sub(r'!(?!=)', ' not ', expression.replace('&&', ' and ').replace('||', ' or ')).strip()
    tree = ast.parse(expression, mode='eval')
    allowed = (ast.Expression, ast.BoolOp, ast.UnaryOp, ast.Not, ast.Compare, ast.Eq, ast.NotEq, ast.Constant, ast.And, ast.Or)
    assert all(isinstance(node, allowed) for node in ast.walk(tree)), expression
    return bool(eval(compile(tree, '<workflow condition>', 'eval'), {'__builtins__': {}}))

# Even conflicting reuse inputs must never boot, build or certify runtime in this mode.
for run_id in ('', '123'):
    for result in ('skipped', 'success', 'failure'):
        assert enabled('validation', True, run_id, result)
        for name in ('candidate', 'runtime-pending', 'runtime', 'runtime-status'):
            assert not enabled(name, True, run_id, result), name
assert enabled('candidate', False, '', 'success')
assert enabled('runtime', False, '', 'success')
assert not enabled('runtime', False, '', 'failure')
assert not enabled('runtime', False, '', 'skipped')
assert enabled('runtime', False, '123', 'skipped')
assert enabled('runtime-status', False)
assert 'uses: ./.github/workflows/dagger-parity.yml' in jobs['validation']
assert 'mode: probe' in jobs['validation'] and 'secrets:' not in jobs['validation']
parity = (root/'.github/workflows/dagger-parity.yml').read_text()
assert '  workflow_call:' in parity
assert 'call: source-contracts ' in parity
assert 'call: check-result --status=${{ runner.temp }}/dagger-source/exit-code' in parity
assert '${{ runner.temp }}/dagger-source\n' in parity
print('PASS: validation-only dispatch cannot build, boot or report runtime acceptance; ordinary gates remain active')
PY
