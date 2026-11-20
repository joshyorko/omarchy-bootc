#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "${ROOT_DIR}" <<'PY'
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

root_dir = Path(sys.argv[1])
keyring_script = root_dir / 'build/pacman-public-keyring.sh'
verifier_path = root_dir / 'scripts/ci/verify-candidate-archive.py'
spec = importlib.util.spec_from_file_location('verify_archive', verifier_path)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

# 1. Real GPG test: build/pacman-public-keyring.sh export + restore must preserve
#    local-signature trust ('f') with zero secret key material in the restored ring.
with tempfile.TemporaryDirectory(prefix='pacman-keyring-test-') as td:
    tmp = Path(td)
    src_ring = tmp / 'src-ring'
    arch_ring = tmp / 'arch-ring'
    pub_dir = tmp / 'public'
    dst_ring = tmp / 'dst-ring'
    src_ring.mkdir(mode=0o700)
    arch_ring.mkdir(mode=0o700)
    subprocess.run(
        ['gpg', '--batch', '--homedir', str(src_ring), '--passphrase', '',
         '--quick-generate-key', 'Local Master <local@test>', 'default', 'default', 'never'],
        check=True, capture_output=True,
    )
    subprocess.run(
        ['gpg', '--batch', '--homedir', str(arch_ring), '--passphrase', '',
         '--quick-generate-key', 'Arch Key <arch@test>', 'default', 'default', 'never'],
        check=True, capture_output=True,
    )
    arch_pub = subprocess.check_output(['gpg', '--batch', '--homedir', str(arch_ring), '--export'])
    subprocess.run(['gpg', '--batch', '--homedir', str(src_ring), '--import'], input=arch_pub, check=True, capture_output=True)
    subprocess.run(['gpgconf', '--homedir', str(arch_ring), '--kill', 'all'], capture_output=True)
    local_fpr = [
        line.split(':')[9]
        for line in subprocess.check_output(
            ['gpg', '--batch', '--homedir', str(src_ring), '--list-secret-keys', '--with-colons'],
            text=True,
        ).splitlines()
        if line.startswith('fpr:')
    ][0]
    arch_fpr = [
        line.split(':')[9]
        for line in subprocess.check_output(
            ['gpg', '--batch', '--homedir', str(arch_ring), '--list-keys', '--with-colons'],
            text=True,
        ).splitlines()
        if line.startswith('fpr:')
    ][0]
    subprocess.run(
        ['gpg', '--batch', '--yes', '--pinentry-mode', 'loopback', '--passphrase', '',
         '--homedir', str(src_ring), '--default-key', local_fpr, '--quick-lsign-key', arch_fpr],
        check=True, capture_output=True,
    )
    env_export = dict(
        os.environ,
        PACMAN_GNUPG_DIR=str(src_ring),
        PACMAN_PUBLIC_DIR=str(pub_dir),
        PACMAN_KEYRING_ALLOW_NON_TMPFS_FOR_TEST='1',
    )
    subprocess.run(['bash', str(keyring_script), 'export'], env=env_export, check=True)
    env_restore = dict(
        os.environ,
        PACMAN_GNUPG_DIR=str(dst_ring),
        PACMAN_PUBLIC_DIR=str(pub_dir),
    )
    subprocess.run(['bash', str(keyring_script), 'restore'], env=env_restore, check=True)
    out = subprocess.check_output(
        ['gpg', '--batch', '--no-autostart', '--homedir', str(dst_ring),
         '--list-keys', '--with-colons', arch_fpr],
        text=True,
    )
    pub_line = [line for line in out.splitlines() if line.startswith('pub:')][0]
    assert pub_line.split(':')[1] == 'f', f'expected full trust via local sig, got: {pub_line}'
    priv = dst_ring / 'private-keys-v1.d'
    assert not priv.exists() or not any(priv.rglob('*')), 'secret key leaked into restored keyring'
    assert not (dst_ring / 'secring.gpg').exists(), 'secring.gpg leaked into restored keyring'
    subprocess.run(['gpgconf', '--homedir', str(dst_ring), '--kill', 'all'], capture_output=True)

# 2. Multi-layer OCI archive scanner test: secret added in layer 1 and whiteout-deleted
#    in layer 2 MUST still be rejected; clean multi-layer archive MUST pass.
def make_layer(entries, compress=True):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as t:
        for name, data in entries:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    raw = buf.getvalue()
    return gzip.compress(raw) if compress else raw

def build_oci(directory, layers_bytes):
    head = 'c' * 40
    archive = directory / 'candidate.oci.tar'
    receipt = directory / 'candidate.receipt.json'
    layer_descs = []
    members = {}
    for blob in layers_bytes:
        d = verifier.digest(blob)
        layer_descs.append({'mediaType': 'application/vnd.oci.image.layer.v1.tar+gzip', 'digest': d, 'size': len(blob)})
        members['blobs/sha256/' + d[7:]] = blob
    config = json.dumps({
        'architecture': 'amd64', 'os': 'linux',
        'config': {'Labels': {'org.opencontainers.image.revision': head}},
        'rootfs': {'type': 'layers', 'diff_ids': [d['digest'] for d in layer_descs]},
    }).encode()
    config_digest = verifier.digest(config)
    manifest = json.dumps({
        'schemaVersion': 2,
        'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'config': {'digest': config_digest, 'mediaType': 'application/vnd.oci.image.config.v1+json', 'size': len(config)},
        'layers': layer_descs,
    }).encode()
    manifest_digest = verifier.digest(manifest)
    members['index.json'] = json.dumps({'schemaVersion': 2, 'manifests': [{'digest': manifest_digest}]}).encode()
    members['blobs/sha256/' + manifest_digest[7:]] = manifest
    members['blobs/sha256/' + config_digest[7:]] = config
    with tarfile.open(archive, 'w') as out:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            out.addfile(info, io.BytesIO(data))
    receipt.write_text(json.dumps({
        'source_head': head, 'archive': archive.name,
        'image_id': config_digest, 'manifest_digest': manifest_digest,
        'archive_sha256': verifier.digest(archive.read_bytes()),
    }))
    return receipt, archive, head

with tempfile.TemporaryDirectory(prefix='oci-layer-scan-test-') as td:
    base = Path(td)
    clean_dir = base / 'clean'
    clean_dir.mkdir()
    l1 = make_layer([('etc/pacman.d/gnupg/pubring.kbx', b'public-only'),
                     ('etc/pacman.d/gnupg/trustdb.gpg', b'trust')])
    l2 = make_layer([('usr/share/omarchy-bootc/pacman-public/public-keys.gpg', b'pub')])
    receipt, archive, head = build_oci(clean_dir, [l1, l2])
    res = verifier.verify(receipt, archive, head)
    assert res['layers_scanned'] == 2

    leaked_dir = base / 'leaked'
    leaked_dir.mkdir()
    bad_l1 = make_layer([('etc/pacman.d/gnupg/private-keys-v1.d/deadbeef.key', b'SECRET')])
    whiteout_l2 = make_layer([('etc/pacman.d/gnupg/private-keys-v1.d/.wh.deadbeef.key', b'')])
    receipt, archive, head = build_oci(leaked_dir, [bad_l1, whiteout_l2])
    try:
        verifier.verify(receipt, archive, head)
    except ValueError as err:
        assert 'forbidden pacman secret material' in str(err), str(err)
    else:
        raise AssertionError('deleted-in-later-layer pacman private key was accepted')

print('PASS: pacman public keyring trust preservation and per-layer OCI secret scan')
PY
