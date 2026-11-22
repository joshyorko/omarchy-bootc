#!/usr/bin/env python3
"""Reject blank startup frames; a human still reviews the retained raw PNG."""
import sys
from PIL import Image


def visible(path):
    with Image.open(path) as frame:
        colors = frame.convert("RGB").resize((160, 100)).getcolors(16000)
    fraction = sum(count for count, rgb in colors if max(rgb) > 20) / 16000
    print(f"VM frame: {len(colors)} colors, {fraction:.3f} nonblack fraction")
    return len(colors) >= 1000 and fraction >= 0.10


if __name__ == "__main__":
    sys.exit(0 if visible(sys.argv[1]) else 1)
