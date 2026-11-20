#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys

spec=importlib.util.spec_from_file_location('adapter',Path(sys.argv[1])/'scripts/ci/adapt-upstream-acceptance.py')
adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)
before,after=adapter.REPLACEMENTS['test/acceptance.d/shell-surfaces-test.sh']
fixture=r'''
set -euo pipefail
GRID_OPEN=0 WRITER_OPEN=0 QUERY=''
omarchy-menu() { [[ $* == 'summon apps' ]]; GRID_OPEN=$GRID_ENABLED; }
layer_on_overlay() { [[ $1 == omarchy-dock-apps && $GRID_OPEN == 1 ]]; }
layer_absent() { [[ $1 == omarchy-dock-apps && $GRID_OPEN == 0 ]]; }
window_present() { [[ $1 == '(?i)omawrite' && $WRITER_OPEN == 1 ]]; }
window_absent() { [[ $1 == '(?i)omawrite' && $WRITER_OPEN == 0 ]]; }
close_windows() { [[ $1 == '(?i)omawrite' ]]; WRITER_OPEN=0; }
wait_until() { local label=$1 timeout=$2; shift 2; printf 'gate:%s timeout:%s\n' "$label" "$timeout"; "$@"; }
wtype() {
 if [[ $* == omawrite ]]; then QUERY=$*;
 elif [[ $* == '-k Return' && $QUERY == omawrite && $WRITER_ENABLED == 1 ]]; then GRID_OPEN=0; WRITER_OPEN=1;
 fi
}
sleep() { :; }
screenshot() { printf 'screenshot:%s\n' "$1"; }
fail() { exit 1; }
'''
for source,grid,writer,expected in ((before,1,1,1),(after,1,1,0),(after,0,1,1),(after,1,0,1)):
    command=fixture+f'\nGRID_ENABLED={grid} WRITER_ENABLED={writer}\n'+source.decode()
    result=subprocess.run(['bash','-c',command],capture_output=True,text=True,timeout=10)
    assert result.returncode==expected,(grid,writer,result.stdout,result.stderr)
    if expected==0:
        assert 'gate:apps menu opens timeout:15' in result.stdout
        assert 'gate:apps menu launches the top search hit timeout:60' in result.stdout
        assert 'gate:apps menu closes after launching timeout:15' in result.stdout
        assert 'gate:Omawrite window closes timeout:30' in result.stdout
        assert result.stdout.count('screenshot:')==2
assert after.count(b'omarchy-dock-apps')==2 and b'"omarchy-menu"' not in after
print('PASS: pinned Apps dock namespace; old assertion fails; missing grid/writer still fail with launch, closure and screenshots preserved')
PY
