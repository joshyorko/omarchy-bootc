#!/usr/bin/env python3
"""Adapt the pinned recipe to current Just and its canonical /app workdir."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
move = '    mv ./output.iso {{ justfile_dir() }} &>/dev/null'
if source.count(move) != 1:
    raise ValueError("Pinned Titanoboa build wrapper changed")
# In /app the final ISO already resides in justfile_dir(); mv rejects the
# identical source/destination. Preserve an explicit nonempty-output gate.
path.write_text("set lists\n" + source.replace(move, "    test -s ./output.iso", 1))
