#!/usr/bin/env python3
"""Guarded Quattro plugin/menu runtime corrections with per-file provenance."""
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
  new_id="local.${USER:-$(id -un)}.${source_id#omarchy.}"
fi
'''

# P1-13: keep menu search focus handoff clean across outputs and avoid
# duplicating the first typed character during synchronous provider/focus stalls.
MENU_SPANS = [
    (
        '    if (!root.dmenuActive && root.filterText.trim()) root.loadProvidersForSearch()\n',
        '    if (!root.dmenuActive && root.filterText.trim()) Qt.callLater(function() { if (root.opened && !root.dmenuActive && root.filterText.trim()) root.loadProvidersForSearch() })\n',
    ),
    (
        '    onShownChanged: if (!shown) { cardTop = -1; maxRowsHeight = -1 }\n'
        '    onTargetScreenChanged: { cardTop = -1; maxRowsHeight = -1 }\n',
        '    onShownChanged: if (!shown) { cardTop = -1; maxRowsHeight = -1 }\n'
        '    onContentRevealedChanged: if (contentRevealed) Qt.callLater(function() { if (panel.shown) filterInput.forceActiveFocus() })\n'
        '    onTargetScreenChanged: { cardTop = -1; maxRowsHeight = -1; if (shown) Qt.callLater(function() { if (panel.shown) filterInput.forceActiveFocus() }) }\n',
    ),
    (
        '        // Focus is on filterInput, which forwards every key here first.\n'
        '        Keys.onPressed: function(event) {\n'
        '          if (root.deleteConfirmOpen) {\n',
        '        // Focus is on filterInput, which forwards every key here first.\n'
        '        Keys.onPressed: function(event) {\n'
        '          if (event.isAutoRepeat && event.text && event.text.length > 0 && !Util.editsFilter(event, root.filterText) && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Escape && event.key !== Qt.Key_Delete && event.key !== Qt.Key_Backspace) {\n'
        '            event.accepted = true\n'
        '            return\n'
        '          }\n'
        '          if (root.deleteConfirmOpen) {\n',
    ),
]


def patch(path, receipt, mode="reload"):
    before = path.read_bytes()
    after = before
    if mode == "menu":
        for old_s, new_s in MENU_SPANS:
            old_b, new_b = old_s.encode(), new_s.encode()
            if after.count(old_b) != 1:
                raise ValueError(f"pinned menu focus source drift: {old_s.splitlines()[0]}")
            after = after.replace(old_b, new_b, 1)
        change = "menu-focus-handoff-and-first-key-dedup"
    else:
        replacements = {"reload": (OLD, NEW), "clone": (CLONE_OLD, CLONE_NEW)}
        if mode not in replacements:
            raise ValueError(f"unknown patch mode: {mode}")
        old_b, new_b = (s.encode() for s in replacements[mode])
        if after.count(old_b) != 1:
            raise ValueError(f"pinned plugin {mode} source drift")
        after = after.replace(old_b, new_b, 1)
        change = "watched-plugin-quickshell-soft-reload" if mode == "reload" else "avoid-clone-builtin-id-collision"
    path.write_bytes(after)
    receipt.write_text(json.dumps({
        "schema": f"omarchy-bootc.plugin-{mode}-patch/v1",
        "before_sha256": hashlib.sha256(before).hexdigest(),
        "after_sha256": hashlib.sha256(after).hexdigest(),
        "change": change,
    }, indent=2) + "\n")


if __name__ == "__main__":
    patch(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else "reload")
