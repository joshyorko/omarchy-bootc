#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$root" <<'PY'
import importlib.util
import os
from pathlib import Path
import tempfile

root = Path(__import__('sys').argv[1])
spec = importlib.util.spec_from_file_location('fs', root/'custom/first-boot/omarchy-adoption-filesystem.py')
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)

def operation(mode, source, name, destination, target, *owner):
    fs.main([mode, str(source), name, str(destination), target, *map(str, owner)])

with tempfile.TemporaryDirectory(prefix='codex-adoption-fd-', dir='/tmp') as temp:
    base=Path(temp)
    home=base/'home'; state=base/'state'; outside=base/'outside'
    for path in (home/'.config/hypr', state, outside/'hypr'):
        path.mkdir(parents=True)
    (home/'.config/hypr/settings').write_text('original')
    (home/'.config/hypr/settings').chmod(0o600)
    (outside/'hypr/secret').write_text('outside')
    (outside/'hypr/secret').chmod(0o600)
    # Same source/backup/restore/seed/rollback paths used by the shell caller.
    operation('copy', home, '.config/hypr', state, 'backup/.config/hypr')
    operation('move', home, '.config/hypr', state, 'after/.config/hypr')
    (state/'after/.config/hypr/settings').write_text('generated')
    (state/'after/.config/hypr/required').write_text('required')
    operation('copy', state, 'backup/.config/hypr', home, '.config/hypr')
    operation('seed', state, 'after/.config/hypr', home, '.config/hypr', os.getuid(), os.getgid())
    assert (home/'.config/hypr/settings').read_text()=='original'
    assert (home/'.config/hypr/settings').stat().st_mode & 0o777 == 0o600
    assert (home/'.config/hypr/required').read_text()=='required'
    operation('move', home, '.config/hypr', state, 'rollback-current/.config/hypr')
    operation('copy', state, 'backup/.config/hypr', home, '.config/hypr')
    assert (state/'rollback-current/.config/hypr/required').read_text()=='required'
    # Swap a source ancestor at the exact directory-open boundary, on either side.
    real_open=fs.os.open
    for when in ('before', 'after'):
        triggered=[False]
        def racing_open(path, flags, *args, **kwargs):
            if path=='.config' and not triggered[0]:
                triggered[0]=True
                fd=real_open(path, flags, *args, **kwargs) if when=='after' else None
                (home/'.config').rename(home/'.saved-config')
                (home/'.config').symlink_to(outside, target_is_directory=True)
                return fd if fd is not None else real_open(path, flags, *args, **kwargs)
            return real_open(path, flags, *args, **kwargs)
        fs.os.open=racing_open
        try:
            try:
                operation('copy', home, '.config/hypr', state, 'race-'+when)
            except OSError:
                assert when=='before'
        finally:
            fs.os.open=real_open
        assert triggered[0]
        assert not (state/('race-'+when)/'secret').exists()
        if when=='after':
            assert (state/'race-after/settings').read_text()=='original'
        (home/'.config').unlink(); (home/'.saved-config').rename(home/'.config')
    # Destination ancestor replacement must not write through an outside link.
    (home/'.config').rename(home/'.saved-config')
    (home/'.config').symlink_to(outside, target_is_directory=True)
    try:
        operation('copy', state, 'backup/.config/hypr', home, '.config/new')
    except OSError:
        pass
    else:
        raise AssertionError('destination symlink traversal accepted')
    assert not (outside/'new').exists()
    (home/'.config').unlink(); (home/'.saved-config').rename(home/'.config')
    # Leaf links stay links, never turn into root reads or recursive deletions.
    (home/'link').symlink_to(outside)
    operation('copy', home, 'link', state, 'link')
    assert (state/'link').is_symlink()
    fs.main(['remove', str(state), 'link'])
    assert (outside/'hypr/secret').read_text()=='outside'
    # A concurrently created destination is preserved, not silently overwritten.
    (state/'occupied').write_text('user data')
    try:
        operation('copy', home, '.config/hypr/settings', state, 'occupied')
    except FileExistsError:
        pass
    else:
        raise AssertionError('concurrent destination overwritten')
    assert (state/'occupied').read_text()=='user data'
    for invalid in ('../outside', '/absolute', 'bad\nrecord', 'bad\tfield'):
        try:
            operation('copy', home, invalid, state, 'invalid')
        except ValueError:
            pass
        else:
            raise AssertionError('unsafe path accepted: '+repr(invalid))
    if os.geteuid()==0:
        (state/'seed-owner').mkdir()
        (state/'after/.config/hypr/link').symlink_to(outside)
        operation('seed', state, 'after/.config/hypr', state, 'seed-owner', 65534, 65534)
        assert (state/'seed-owner/required').stat().st_uid==65534
        assert (state/'seed-owner/required').stat().st_gid==65534
        assert (state/'seed-owner/link').lstat().st_uid==65534
        assert (outside/'hypr/secret').stat().st_uid==0
        print('PASS: real root helper preserves intended seeding UID/GID')
print('PASS: descriptor-confined backup/restore/seed/rollback, source/destination races, leaf links and no-clobber publication')
PY
