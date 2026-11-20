#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Offline default: exact compressed upstream acceptance fixture, not a VM substitute.
# Optional argument: an independently fetched pristine checkout at the pinned revision.
python3 -B - "$ROOT_DIR" "$@" <<'PY'
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zlib

PINNED_FIXTURE = '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'
root = Path(sys.argv[1])
script = root / "scripts/ci/adapt-upstream-acceptance.py"
spec = importlib.util.spec_from_file_location("adapter", script)
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)

fixture = {name: text.encode() for name, text in
           json.loads(zlib.decompress(base64.b64decode(PINNED_FIXTURE))).items()}
if len(sys.argv) > 2:
    source = Path(sys.argv[2])
    assert {p.name for p in (source / "test/acceptance.d").iterdir()} == {
        Path(p).name for p in fixture if p.startswith("test/acceptance.d/")}
    fixture = {name: (source / name).read_bytes() for name in fixture}
for name, data in fixture.items():
    assert hashlib.sha256(data).hexdigest() == adapter.UPSTREAM_SHA256[name], name

with tempfile.TemporaryDirectory() as temporary:
    tmp = Path(temporary)
    def stage(name):
        target = tmp / name
        (target / "test/acceptance.d").mkdir(parents=True)
        for path, data in fixture.items():
            (target / path).write_bytes(data)
        return target

    def run(target, artifacts, revision=adapter.REVISION):
        return subprocess.run([sys.executable, str(script), "--upstream-root", str(target),
                               "--revision", revision, "--artifacts", str(artifacts)],
                              capture_output=True, text=True)

    target = stage("valid")
    artifacts = tmp / "receipt"
    result = run(target, artifacts)
    assert result.returncode == 0, result.stderr
    receipt = json.loads((artifacts / "upstream-acceptance-adaptation.json").read_bytes())
    assert receipt["patch_sha256"] == adapter.sha256((artifacts / receipt["patch"]).read_bytes())
    assert receipt["status"] == "adapted-not-executed"
    assert len(receipt["changes"]) == 2 and receipt["skipped_tests"] == []
    # Enforce the consumer-visible boundary: every original byte outside the two
    # selected assertion spans survives, and runner discovery includes every gate.
    for name, before in fixture.items():
        after = (target / name).read_bytes()
        if name in adapter.REPLACEMENTS:
            old, new = adapter.REPLACEMENTS[name]
            prefix, suffix = before.split(old)
            assert after == prefix + new + suffix, name
        else:
            assert after == before, name
        assert receipt["original_sha256"][name] == adapter.sha256(before)
        assert receipt["adapted_sha256"][name] == adapter.sha256(after)
    required = {"apps-test.sh", "cups-test.sh", "menu-test.sh", "panels-test.sh",
                "security-test.sh", "session-test.sh", "shell-surfaces-test.sh", "system-test.sh"}
    discovered = {p.name for p in (target / "test/acceptance.d").glob("*-test.sh")
                  if p.name != "base-test.sh"}
    assert discovered == required == {Path(p).name for p in receipt["required_tests"]}
    assert (target / adapter.HELPER_PATH).read_bytes() == script.with_name("guest-bootc-acceptance.sh").read_bytes()
    helper_text = script.with_name("guest-bootc-acceptance.sh").read_text()
    assert 'bootc_kernel_headers_path_allowed "$headers" "$modules"' in helper_text
    # Audit diff must independently reconstruct the entire staged suite.
    reconstructed = stage("reconstructed")
    if shutil.which("patch"):
        patch_command = ["patch", "--batch", "-p1", "-i", str(artifacts / receipt["patch"])]
    else:
        patch_command = ["git", "apply", "--unsafe-paths", "-p1", str(artifacts / receipt["patch"])]
    patched = subprocess.run(patch_command, cwd=reconstructed, capture_output=True, text=True)
    assert patched.returncode == 0, patched.stderr
    for name, expected in receipt["adapted_sha256"].items():
        assert adapter.sha256((reconstructed / name).read_bytes()) == expected, name

    # Changing ANY original gate, removing it, changing the pin, adding a runner
    # test, or attempting a second adaptation must fail closed before mutation.
    for index, path in enumerate(fixture):
        for mutation in ("drift", "missing", "symlink"):
            damaged = stage(f"{index}-{mutation}")
            file = damaged / path
            if mutation == "drift":
                file.write_bytes(file.read_bytes() + b"\n# drift\n")
            else:
                file.unlink()
                if mutation == "symlink":
                    file.symlink_to(target / path)
            out = tmp / f"refused-{index}-{mutation}"
            snapshot = {p: (damaged / p).read_bytes() for p in fixture if (damaged / p).exists()}
            result = run(damaged, out)
            assert result.returncode != 0, (path, mutation)
            assert not out.exists()
            assert snapshot == {p: (damaged / p).read_bytes() for p in snapshot}
    for case in ("pin", "extra", "already-adapted"):
        damaged = stage(case)
        if case == "extra":
            (damaged / "test/acceptance.d/extra-test.sh").write_text("exit 0\n")
        if case == "already-adapted":
            assert run(damaged, tmp / "first-adaptation").returncode == 0
        out = tmp / ("refused-" + case)
        assert run(damaged, out, "0" * 40 if case == "pin" else adapter.REVISION).returncode != 0
        assert not out.exists()

    # Parsing fixtures are never runtime evidence. No bootc/findmnt/pacman mocks.
    digest = "a" * 128
    root_mount = {"filesystems": [{"target": "/", "source": "composefs:" + digest,
        "fstype": "overlay", "options": "ro,relatime,lowerdir=/::/objects,redirect_dir=on,metacopy=on"}]}
    backing = {"filesystems": [{"target": "/sysroot", "source": "/dev/vda3", "fstype": "btrfs", "options": "ro,relatime"}]}
    status = {"status": {"booted": {"composefs": {"verity": digest}, "ostree": None,
              "image": {"imageDigest": "sha256:" + "b" * 64}}}}
    def validate(r, b, s):
        paths = [tmp / "root.json", tmp / "backing.json", tmp / "status.json"]
        for path, data in zip(paths, (r, b, s)):
            path.write_text(json.dumps(data))
        return subprocess.run(["bash", "-c", 'source "$1"; bootc_validate_root "$2" "$3" "$4"',
                               "parser-test", str(script.with_name("guest-bootc-acceptance.sh")),
                               *map(str, paths)], capture_output=True).returncode == 0
    assert validate(root_mount, backing, status)
    import copy
    for field, value in (("fstype", "btrfs"), ("source", "overlay"),
                         ("source", "composefs:" + "c" * 128),
                         ("source", "transient:composefs=" + digest),
                         ("target", "/wrong"), ("options", "rw,metacopy=on,redirect_dir=on"),
                         ("options", "ro,metacopy=on,redirect_dir=on,upperdir=/tmp/u"),
                         ("options", "ro,metacopy=off,redirect_dir=on")):
        changed = copy.deepcopy(root_mount)
        changed["filesystems"][0][field] = value
        assert not validate(changed, backing, status), (field, value)
    for field, value in (("fstype", "ext4"), ("target", "/"), ("options", "rw,relatime")):
        changed = copy.deepcopy(backing)
        changed["filesystems"][0][field] = value
        assert not validate(root_mount, changed, status), (field, value)
    for invalid in ({"status": {"booted": None, "staged": status["status"]["booted"]}},
                    {"status": {"booted": {"image": {"composefs": {"verity": digest}}}}},
                    {"status": {"booted": dict(status["status"]["booted"], ostree={})}},
                    {"status": {"booted": dict(status["status"]["booted"], composefs={"verity": "bad"})}}):
        assert not validate(root_mount, backing, invalid)
    assert not validate({"filesystems": []}, backing, status)
    assert not validate({"filesystems": root_mount["filesystems"] * 2}, backing, status)
print("PASS: exact two-assertion adaptation, preserved gates, drift refusal, and root parser boundaries (not a VM pass)")
PY
