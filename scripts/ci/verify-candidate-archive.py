#!/usr/bin/env python3
"""Verify OCI bytes/config identity and scan every layer before warm-store load."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import posixpath
import re
import subprocess
import tarfile
import threading


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def sha(value):
    value = value if value.startswith('sha256:') else 'sha256:' + value
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', value):
        raise ValueError('invalid SHA-256 identity')
    return value


class _HashingReader(io.RawIOBase):
    """Wrap a sequential binary stream while computing its SHA-256 digest."""

    def __init__(self, stream, prefix=b''):
        self._stream = stream
        self._prefix = prefix
        self._hasher = hashlib.sha256()

    def readable(self):
        return True

    def read(self, size=-1):
        if size == 0:
            return b''
        if self._prefix:
            if size < 0 or size >= len(self._prefix):
                chunk = self._prefix
                self._prefix = b''
            else:
                chunk = self._prefix[:size]
                self._prefix = self._prefix[size:]
            self._hasher.update(chunk)
            if size < 0:
                rest = self._stream.read()
                if rest:
                    self._hasher.update(rest)
                return chunk + rest
            return chunk
        chunk = self._stream.read(size)
        if chunk:
            self._hasher.update(chunk)
        return chunk

    def readinto(self, buffer):
        data = self.read(len(buffer))
        n = len(data)
        buffer[:n] = data
        return n

    def drain_and_digest(self):
        while self.read(1024 * 1024):
            pass
        return 'sha256:' + self._hasher.hexdigest()


def _normalize_member_path(name):
    cleaned = posixpath.normpath('/' + name.lstrip('/')).lstrip('/')
    return '' if cleaned == '.' else cleaned


def _forbidden_secret_path(member):
    path = _normalize_member_path(member.name)
    if not path:
        return None
    base = posixpath.basename(path)
    if base.startswith('.wh.'):
        return None
    if path.startswith('etc/pacman.d/gnupg/'):
        if path.startswith('etc/pacman.d/gnupg/private-keys-v1.d/') and not member.isdir():
            return path
        if path in ('etc/pacman.d/gnupg/secring.gpg', 'etc/pacman.d/gnupg/random_seed') and not member.isdir():
            return path
        if base.startswith('S.gpg-agent') or (base.endswith('.key') and not member.isdir()):
            return path
    if path.startswith('usr/share/omarchy-bootc/pacman-public/'):
        if base == 'secring.gpg' or base.endswith('.key') or '/private-keys-v1.d/' in ('/' + path):
            return path
    return None


def _scan_tar_stream(stream, layer_digest):
    with tarfile.open(fileobj=stream, mode='r|*') as layer_tar:
        for member in layer_tar:
            forbidden = _forbidden_secret_path(member)
            if forbidden is not None:
                raise ValueError(
                    f'forbidden pacman secret material in layer {layer_digest}: {forbidden}'
                )


def _scan_layer_blob(raw_stream, expected_digest):
    magic = raw_stream.read(4)
    if magic == b'\x28\xb5\x2f\xfd':
        hasher = hashlib.sha256()
        hasher.update(magic)
        proc = subprocess.Popen(
            ['zstd', '-dc'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        write_error = []

        def _feed():
            try:
                proc.stdin.write(magic)
                while True:
                    chunk = raw_stream.read(1024 * 1024)
                    if not chunk:
                        break
                    hasher.update(chunk)
                    proc.stdin.write(chunk)
            except BrokenPipeError:
                pass
            except Exception as exc:
                write_error.append(exc)
            finally:
                try:
                    proc.stdin.close()
                except OSError:
                    pass

        feeder = threading.Thread(target=_feed, daemon=True)
        feeder.start()
        try:
            _scan_tar_stream(proc.stdout, expected_digest)
            while proc.stdout.read(1024 * 1024):
                pass
        finally:
            try:
                proc.stdout.close()
            except OSError:
                pass
            feeder.join()
            stderr = proc.stderr.read()
            proc.stderr.close()
            rc = proc.wait()
        if write_error:
            raise write_error[0]
        if rc != 0:
            raise ValueError(f'failed to decompress zstd layer {expected_digest}: {stderr.decode(errors="replace").strip()}')
        actual_digest = 'sha256:' + hasher.hexdigest()
    else:
        reader = _HashingReader(raw_stream, prefix=magic)
        _scan_tar_stream(reader, expected_digest)
        actual_digest = reader.drain_and_digest()
    if actual_digest != expected_digest:
        raise ValueError(f'candidate layer blob hash mismatch: {expected_digest} != {actual_digest}')


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
        members_by_name = {}
        for member in archive.getmembers():
            members_by_name.setdefault(member.name, []).append(member)

        def get_unique_member(name, max_size=None):
            matches = members_by_name.get(name, [])
            if len(matches) != 1 or not matches[0].isfile():
                raise ValueError('missing or ambiguous OCI member: ' + name)
            if max_size is not None and matches[0].size > max_size:
                raise ValueError('oversized OCI metadata: ' + name)
            return matches[0]

        def read(name):
            member = get_unique_member(name, max_size=4 * 1024 * 1024)
            return archive.extractfile(member).read()

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
        layers = manifest.get('layers', [])
        for layer in layers:
            layer_digest = sha(layer['digest'])
            layer_member = get_unique_member('blobs/sha256/' + layer_digest.removeprefix('sha256:'))
            with archive.extractfile(layer_member) as layer_stream:
                _scan_layer_blob(layer_stream, layer_digest)
    return {'source_head': head, 'archive_sha256': actual_checksum,
            'manifest_digest': manifest_digest, 'config_digest': config_digest,
            'image_id': config_digest.removeprefix('sha256:'), 'layers_scanned': len(layers)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('receipt', type=Path)
    parser.add_argument('archive', type=Path)
    parser.add_argument('head')
    args = parser.parse_args()
    print(json.dumps(verify(args.receipt, args.archive, args.head), indent=2))
