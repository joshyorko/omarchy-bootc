#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${ROOT_DIR}/scripts/ci/lib/runtime-artifacts.py"
# Exercise real filesystem boundaries, not source-text or mocked command calls.
python3 - "${helper}" <<'PY'
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

helper = sys.argv[1]
uid, gid = os.getuid(), os.getgid()

def run(tree, succeeds=True):
    result = subprocess.run([sys.executable, helper, str(tree), str(uid), str(gid)],
                            capture_output=True, text=True)
    assert (result.returncode == 0) == succeeds, result.stderr

with tempfile.TemporaryDirectory(prefix="runtime-artifacts-") as tmp:
    base = Path(tmp)
    tree = base / "receipts"
    tree.mkdir()
    nested = tree / "nested"
    nested.mkdir()
    receipt = nested / "serial.log"
    receipt.write_text("serial receipt\n")
    receipt.chmod(0o400)
    nested.chmod(0o500)
    outside = base / "outside.log"
    outside.write_text("untouched\n")
    outside.chmod(0o400)
    before = outside.stat()
    (tree / "external-link").symlink_to(outside)
    (tree / "directory-link").symlink_to(base, target_is_directory=True)
    os.mkfifo(tree / "fifo", 0o600)
    run(tree)
    assert receipt.read_text() == "serial receipt\n"
    assert stat.S_IMODE(receipt.stat().st_mode) == 0o600
    assert stat.S_IMODE(nested.stat().st_mode) == 0o700
    assert (outside.stat().st_mode, outside.stat().st_uid, outside.stat().st_gid) == (
        before.st_mode, before.st_uid, before.st_gid)
    assert (tree / "external-link").is_symlink()
    assert stat.S_ISFIFO((tree / "fifo").stat().st_mode)
    # Neither a linked root nor a symlinked ancestor grants authority.
    alias = base / "alias"
    alias.symlink_to(tree, target_is_directory=True)
    run(alias, False)
    run(alias / "nested", False)
    hardlinks = base / "hardlinks"
    hardlinks.mkdir()
    os.link(outside, hardlinks / "receipt")
    run(hardlinks, False)
    assert stat.S_IMODE(outside.stat().st_mode) == 0o400
    run(Path("/"), False)
print("PASS: artifact readability and symlink/hardlink/filesystem-root boundaries")
PY

if (( EUID == 0 )); then
    if ! id nobody >/dev/null 2>&1 || ! command -v runuser >/dev/null 2>&1; then
        echo 'SKIP: root-created receipt case requires the nobody fixture account'
    else
        target_uid="$(id -u nobody)"
        target_gid="$(id -g nobody)"
        tmp="$(mktemp -d)"
        trap 'rm -rf -- "$tmp"' EXIT
        install -d -m 0700 "$tmp/receipts/private"
        printf 'root serial receipt\n' >"$tmp/receipts/private/serial.log"
        chmod 0600 "$tmp/receipts/private/serial.log"
        if runuser -u nobody -- cat "$tmp/receipts/private/serial.log" 2>/dev/null; then
            echo 'FAIL: root-created fixture was already runner-readable' >&2
            exit 1
        fi
        # shellcheck source=scripts/ci/lib/runtime-artifacts.sh
        source "${ROOT_DIR}/scripts/ci/lib/runtime-artifacts.sh"
        normalize_runtime_artifacts "$tmp/receipts" "$target_uid" "$target_gid"
        [[ "$(runuser -u nobody -- cat "$tmp/receipts/private/serial.log")" == 'root serial receipt' ]]
        [[ "$(stat -c '%u:%g' "$tmp/receipts/private/serial.log")" == "${target_uid}:${target_gid}" ]]
        echo 'PASS: root-created 0700/0600 receipts become runner-readable'
    fi
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    tmp="$(mktemp -d)"
    trap 'sudo -n rm -rf -- "$tmp"' EXIT
    sudo -n install -d -m 0700 "$tmp/receipts/private"
    printf 'root serial receipt\n' | sudo -n tee "$tmp/receipts/private/serial.log" >/dev/null
    sudo -n chmod 0600 "$tmp/receipts/private/serial.log"
    if cat "$tmp/receipts/private/serial.log" 2>/dev/null; then
        echo 'FAIL: root-created fixture was already runner-readable' >&2
        exit 1
    fi
    # shellcheck source=scripts/ci/lib/runtime-artifacts.sh
    source "${ROOT_DIR}/scripts/ci/lib/runtime-artifacts.sh"
    normalize_runtime_artifacts "$tmp/receipts"
    [[ "$(cat "$tmp/receipts/private/serial.log")" == 'root serial receipt' ]]
    [[ "$(stat -c '%u:%g' "$tmp/receipts/private/serial.log")" == "$(id -u):$(id -g)" ]]
    echo 'PASS: root-created 0700/0600 receipts become runner-readable'
else
    echo 'SKIP: root-created receipt case requires root or passwordless sudo'
fi
