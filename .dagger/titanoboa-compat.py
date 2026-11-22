#!/usr/bin/env python3
"""Adapt the pinned recipe to current Just and its canonical /app workdir."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
move = '    mv ./output.iso {{ justfile_dir() }} &>/dev/null'
query = '        if ! rpm -q $rpm >/dev/null; then'
if source.count(move) != 1 or source.count(query) != 1:
    raise ValueError("Pinned Titanoboa build wrapper or RPM query changed")
# In /app the final ISO already resides in justfile_dir(); mv rejects the
# identical source/destination. Preserve an explicit nonempty-output gate.
# Fedora satisfies grub2/grub2-efi/shim through architecture-specific RPMs.
# Query real installed providers; absent capabilities must still be missing.
source = source.replace(query, '        if ! rpm -q --whatprovides "$rpm" >/dev/null; then', 1)
path.write_text("set lists\n" + source.replace(move, "    test -s ./output.iso", 1))
