#!/usr/bin/env python3
"""Bind one stage to a previously built local image, without rewriting its logic."""
import argparse
from pathlib import Path
import re


def render(source, stage, parent, image_id):
    if not re.fullmatch(r'(sha256:)?[0-9a-f]{64}', image_id):
        raise ValueError('parent must be an immutable local image ID')
    image_id = image_id.removeprefix('sha256:')
    old = f'FROM {parent} AS {stage}'
    lines = source.splitlines(keepends=True)
    matches = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == old]
    if len(matches) != 1:
        raise ValueError('expected exactly one stage boundary: ' + old)
    index = matches[0]
    lines[index] = lines[index].replace(old, f'FROM {image_id} AS {stage}', 1)
    return ''.join(lines)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'stage', 'parent', 'image_id', 'output'):
        parser.add_argument(name)
    args = parser.parse_args()
    Path(args.output).write_text(render(Path(args.source).read_text(), args.stage, args.parent, args.image_id))
