#!/usr/bin/env python3
"""Parse the real pinned Titanoboa recipe with current Just; execute no build."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
original = Path(sys.argv[1]).read_text()
module = (root / ".dagger/main.go").read_text()
command = re.search(r"`(sed -i '1i set lists' /tmp/titanoboa/Justfile)`", module)
assert command, "Dagger must prepare the pinned recipe before invoking Just"
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
    subprocess.run(["bash", "-eu", "-c", command[1].replace("/tmp/titanoboa/Justfile", str(recipe))], check=True)
    after = subprocess.run(["just", "--justfile", str(recipe), "--evaluate", "PODMAN"], env=env, capture_output=True, text=True, check=True)
    assert after.stdout.strip() == str(podman)
    subprocess.run(["just", "--justfile", str(recipe), "--summary"], env=env, check=True, stdout=subprocess.DEVNULL)
    assert recipe.read_text().split("\n", 1)[1] == original
print("PASS: full pinned Titanoboa recipe fails before compatibility setting and parses afterward; no ISO build executed")
