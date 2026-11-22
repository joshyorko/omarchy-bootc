#!/usr/bin/env python3
"""Parse the real pinned Titanoboa recipe with current Just; execute no build."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
original = Path(sys.argv[1]).read_text()
with tempfile.TemporaryDirectory(prefix="codex-iso-just-", dir="/tmp") as temp:
    path = Path(temp)
    recipe = path / "Justfile"
    recipe.write_text(original)
    podman = path / "podman"
    podman.write_text("#!/bin/sh\nexit 97\n")
    podman.chmod(0o755)
    env = dict(os.environ, PATH=temp + os.pathsep + os.environ["PATH"])
    before = subprocess.run(["just", "--justfile", str(recipe), "--evaluate", "PODMAN"], env=env, capture_output=True, text=True)
    assert before.returncode != 0 and "requires `set lists`" in before.stderr
    # Lists alone leaves the real @build wrapper failing on its final mv-to-self.
    recipe.write_text("set lists\n" + original)
    output = path / "output.iso"
    output.write_text("filesystem-output fixture, not an installer ISO")
    wrapper_before = subprocess.run(["just", "--justfile", str(recipe), "--no-deps", "build"], env=env, capture_output=True)
    assert wrapper_before.returncode != 0
    recipe.write_text(original)
    subprocess.run(["python3", "-B", str(root / ".dagger/titanoboa-compat.py"), str(recipe)], check=True)
    after = subprocess.run(["just", "--justfile", str(recipe), "--evaluate", "PODMAN"], env=env, capture_output=True, text=True, check=True)
    assert after.stdout.strip() == str(podman)
    subprocess.run(["just", "--justfile", str(recipe), "--summary"], env=env, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["just", "--justfile", str(recipe), "--no-deps", "build"], env=env, check=True)
    assert output.read_text() == "filesystem-output fixture, not an installer ISO"
    output.unlink()
    missing = subprocess.run(["just", "--justfile", str(recipe), "--no-deps", "build"], env=env, capture_output=True)
    assert missing.returncode != 0
    expected = original.replace('    mv ./output.iso {{ justfile_dir() }} &>/dev/null', '    test -s ./output.iso', 1)
    assert recipe.read_text() == "set lists\n" + expected
    assert 'Cannot run in nested containers' in recipe.read_text()
print("PASS: real pinned parser and final wrapper regressions; missing output rejected; nesting guard unchanged; no ISO build executed")
