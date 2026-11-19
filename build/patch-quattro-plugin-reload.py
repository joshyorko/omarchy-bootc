#!/usr/bin/env python3
"""Use Quickshell's engine reload for watched QML, not cached components."""
import hashlib
import json
from pathlib import Path
import sys

OLD = """    id: localPluginReloadTimer
    interval: 150
    onTriggered: shell.reloadPlugins()
"""
NEW = OLD.replace("shell.reloadPlugins()", "Quickshell.reload(false)")


def patch(path, receipt):
    before = path.read_bytes()
    old, new = OLD.encode(), NEW.encode()
    if before.count(old) != 1:
        raise ValueError("pinned local-plugin reload timer drift")
    after = before.replace(old, new, 1)
    path.write_bytes(after)
    receipt.write_text(json.dumps({
        "schema": "omarchy-bootc.plugin-reload-patch/v1",
        "before_sha256": hashlib.sha256(before).hexdigest(),
        "after_sha256": hashlib.sha256(after).hexdigest(),
        "change": "watched-plugin-quickshell-soft-reload",
    }, indent=2) + "\n")


if __name__ == "__main__":
    patch(Path(sys.argv[1]), Path(sys.argv[2]))
