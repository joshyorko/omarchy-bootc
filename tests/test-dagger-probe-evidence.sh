#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(sys.argv[1]) / 'scripts/ci/dagger-candidate.sh').read_text()
body = source.split('    probe)\n', 1)[1].split('\n        ;;', 1)[0]
with tempfile.TemporaryDirectory(prefix='codex-omarchy-probe-test-', dir='/tmp') as tmp:
    root = Path(tmp)
    binary = root / 'bin'
    binary.mkdir()
    timer = binary / 'probe-test-time'
    timer.write_text('#!/usr/bin/env bash\nprintf "fixture timer\\n" >"$3"\nshift 3\nexec "$@"\n')
    timer.chmod(0o755)
    podman = binary / 'podman'
    podman.write_text('''#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    info) echo 'rootless: false' ;;
    run) exit "$TEST_RUN_RC" ;;
    build)
        if [[ ! -e $TEST_COUNT ]]; then
            touch "$TEST_COUNT"; exit "$TEST_COLD_RC"
        fi ;;
    image) echo '{}' ;;
    *) exit 99 ;;
esac
''')
    podman.chmod(0o755)
    for name, run_rc, cold_rc, expected in [('failure', 126, 125, 1), ('success', 0, 0, 0)]:
        output = root / name
        output.mkdir()
        env = dict(os.environ, PATH=str(binary)+':'+os.environ['PATH'],
                   TEST_RUN_RC=str(run_rc), TEST_COLD_RC=str(cold_rc),
                   TEST_COUNT=str(output/'count'))
        command = body.replace('/out', str(output)).replace('/usr/bin/time', str(timer))
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', command],
                                env=env, capture_output=True, text=True, timeout=15)
        assert result.returncode == expected, (name, result.returncode, result.stderr)
        for filename, code in [('nested-run.exit-code', run_rc), ('probe-cold.exit-code', cold_rc), ('probe-warm.exit-code', 0)]:
            actual = (output/filename).read_text().strip()
            assert actual == str(code), (name, filename, actual, code)
        assert (output/'probe-image.json').exists()
print('PASS: failed nested run/build retain independent evidence and fail qualification')
PY
