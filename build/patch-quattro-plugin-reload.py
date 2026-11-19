#!/usr/bin/env python3
"""Guarded Quattro plugin runtime corrections with per-file provenance."""
import hashlib
import json
from pathlib import Path
import sys

OLD = """    id: localPluginReloadTimer
    interval: 150
    onTriggered: shell.reloadPlugins()
"""
NEW = OLD.replace("shell.reloadPlugins()", "Quickshell.reload(false)")
CLONE_OLD = 'new_id="${USER:-$(id -un)}.${source_id#omarchy.}"\n'
CLONE_NEW = CLONE_OLD + '''# The legitimate username omarchy must not collide with a built-in id.
if [[ $new_id == "$source_id" ]]; then
  new_id="${USER:-$(id -un)}.local.${source_id#omarchy.}"
fi
'''


def patch(path, receipt, mode="reload"):
    before = path.read_bytes()
    replacements = {"reload": (OLD, NEW), "clone": (CLONE_OLD, CLONE_NEW)}
    old, new = (s.encode() for s in replacements[mode])
    if before.count(old) != 1:
        raise ValueError(f"pinned plugin {mode} source drift")
    after = before.replace(old, new, 1)
    path.write_bytes(after)
    receipt.write_text(json.dumps({
        "schema": f"omarchy-bootc.plugin-{mode}-patch/v1",
        "before_sha256": hashlib.sha256(before).hexdigest(),
        "after_sha256": hashlib.sha256(after).hexdigest(),
        "change": "watched-plugin-quickshell-soft-reload" if mode == "reload" else "avoid-clone-builtin-id-collision",
    }, indent=2) + "\n")


if __name__ == "__main__":
    patch(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else "reload")
