#!/usr/bin/env python3
"""Verify OCI bytes/config identity before consulting any warm image store."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def sha(value):
    value = value if value.startswith('sha256:') else 'sha256:' + value
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', value):
        raise ValueError('invalid SHA-256 identity')
    return value


def verify(receipt_path, archive_path, head):
    receipt = json.loads(receipt_path.read_text())
    if receipt.get('source_head') != head or not re.fullmatch(r'[0-9a-f]{40}', head):
        raise ValueError('candidate source identity mismatch')
    if receipt.get('archive') != archive_path.name or Path(receipt['archive']).name != receipt['archive']:
        raise ValueError('candidate archive name mismatch')
    with archive_path.open('rb') as stream:
        actual_checksum = 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()
    if actual_checksum != receipt['archive_sha256']:
        raise ValueError('candidate archive checksum mismatch')
    with tarfile.open(archive_path, 'r:') as archive:
        def read(name):
            matches = [member for member in archive.getmembers() if member.name == name]
            if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 4 * 1024 * 1024:
                raise ValueError('missing, ambiguous or oversized OCI metadata: ' + name)
            return archive.extractfile(matches[0]).read()
        index = json.loads(read('index.json'))
        manifests = index.get('manifests', [])
        if len(manifests) != 1:
            raise ValueError('expected one platform manifest')
        manifest_digest = sha(manifests[0]['digest'])
        if manifest_digest != receipt['manifest_digest']:
            raise ValueError('candidate manifest differs from receipt')
        manifest_bytes = read('blobs/sha256/' + manifest_digest.removeprefix('sha256:'))
        if digest(manifest_bytes) != manifest_digest:
            raise ValueError('candidate manifest blob hash mismatch')
        manifest = json.loads(manifest_bytes)
        config_digest = sha(manifest['config']['digest'])
        if config_digest != sha(receipt['image_id']):
            raise ValueError('archive config differs from recorded image ID')
        config_bytes = read('blobs/sha256/' + config_digest.removeprefix('sha256:'))
        if digest(config_bytes) != config_digest:
            raise ValueError('candidate config blob hash mismatch')
        config = json.loads(config_bytes)
        if config.get('config', {}).get('Labels', {}).get('org.opencontainers.image.revision') != head:
            raise ValueError('candidate config revision differs from source SHA')
        if config.get('architecture') != 'amd64' or config.get('os') != 'linux':
            raise ValueError('candidate platform is not linux/amd64')
    return {'source_head': head, 'archive_sha256': actual_checksum,
            'manifest_digest': manifest_digest, 'config_digest': config_digest,
            'image_id': receipt['image_id']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('receipt', type=Path)
    parser.add_argument('archive', type=Path)
    parser.add_argument('head')
    args = parser.parse_args()
    print(json.dumps(verify(args.receipt, args.archive, args.head), indent=2))
