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
    assert len(receipt["changes"]) == 6 and receipt["skipped_tests"] == []
    # Exercise the adapted OCR function at its external capture/recognition
    # boundaries. Diagnostic failures must never turn an OCR miss into a pass.
    import os
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    commands = {
        "grim": 'printf "%s" "$FRAME" >"${@: -1}"',
        "tesseract": 'printf "%s" "$OCR_TEXT"; exit "$OCR_EXIT"',
        "omarchy-shell": 'printf "{}"; exit 7',
        "hyprctl": 'printf "[]"; exit 7',
    }
    for name, body in commands.items():
        executable = bin_dir / name
        executable.write_text("#!/usr/bin/env bash\n" + body + "\n")
        executable.chmod(0o755)
    function_file = tmp / "ocr.sh"
    function_file.write_bytes(adapter.REPLACEMENTS["test/acceptance.d/base-test.sh"][1])
    capture_dir = tmp / "ocr-receipts"
    capture_dir.mkdir()
    for index, (text, ocr_exit, expected) in enumerate([
            ("Acceptance notification", "0", 0), ("wrong text", "0", 1),
            ("Acceptance notification", "9", 9)]):
        env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"],
                   FRAME=str(index), OCR_TEXT=text, OCR_EXIT=ocr_exit)
        result = subprocess.run(["bash", "-c",
            'set -uo pipefail; source "$1"; ARTIFACTS="$2"; screen_contains "Acceptance notification"',
            "ocr-test", str(function_file), str(capture_dir)], env=env, capture_output=True)
        assert result.returncode == expected, result.stderr
        assert (capture_dir / "notification-ocr-first.png").read_text() == "0"
        assert (capture_dir / "notification-ocr-latest.png").read_text() == str(index)
        assert (capture_dir / "notification-ocr-latest.txt").read_text() == text
    menu_before = fixture["test/acceptance.d/menu-test.sh"].decode().splitlines()
    menu_after = (target / "test/acceptance.d/menu-test.sh").read_text().splitlines()
    def gates(lines):
        return [line for line in lines if line.strip().startswith(('wait_until ', 'pass ', 'fail ', 'screenshot '))]
    assert gates(menu_before) == gates(menu_after), "menu correction removed or changed a gate"
    # Enforce the consumer-visible boundary: every original byte outside the selected
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
                "security-test.sh", "session-test.sh", "shell-surfaces-test.sh", "system-test.sh",
                "input-methods-test.sh", "overlay-monitor-test.sh"}
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
    observed = copy.deepcopy(root_mount)
    observed["filesystems"][0]["options"] = "ro,relatime,lowerdir=/proc/self/fd/5::/proc/self/fd/6,index=off,verity=require"
    assert validate(observed, backing, status), "readonly verity-required mount from hosted guest was rejected"
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
# Full-screen transparent surfaces have identical dimensions for both bar positions.
# Acceptance must prove the actual reserved edge and a live bar on that monitor.
with tempfile.TemporaryDirectory(prefix="bar-reservations-") as directory:
    tmp = Path(directory)
    monitor_path, layer_path = tmp/"monitors.json", tmp/"layers.json"
    def bar(reserved, orientation, namespace="omarchy-bar", focused=True):
        monitor_path.write_text(json.dumps([{"name":"Virtual-1", "focused":focused, "reserved":reserved}]))
        layer_path.write_text(json.dumps({"Virtual-1":{"levels":{"2":[{"namespace":namespace,"w":1280,"h":800}]}}}))
        result = subprocess.run(["bash", "-c", 'source "$1"; bootc_validate_bar "$2" "$3" "$4"',
                                 "bar-test", str(script.with_name("guest-bootc-acceptance.sh")),
                                 str(monitor_path), str(layer_path), orientation], capture_output=True)
        return result.returncode == 0
    assert bar([28,0,0,0], "vertical")
    assert bar([0,0,28,0], "vertical")
    assert bar([0,28,0,0], "horizontal")
    assert bar([0,0,0,28], "horizontal")
    assert not bar([0,28,0,0], "vertical")
    assert not bar([28,0,0,0], "horizontal")
    assert not bar([0,0,0,0], "vertical")
    assert not bar([28,0,0,0], "vertical", namespace="other-panel")
    assert not bar([28,0,0,0], "vertical", focused=False)
    assert not bar([28,0,0], "vertical")
    assert not bar(["28",0,0,0], "vertical")

# P2-01 & P1-13 unit fixtures: notification layer bounds cropping and strict
# single-first-character Keybindings menu search validation.
with tempfile.TemporaryDirectory(prefix="notif-menu-fixtures-") as directory:
    tmp = Path(directory)
    helper = str(script.with_name("guest-bootc-acceptance.sh"))
    m_path, l_path = tmp / "monitors.json", tmp / "layers.json"
    m_path.write_text(json.dumps([{"name": "Virtual-1", "focused": True, "x": 0, "y": 0, "width": 1280, "height": 800}]))
    l_path.write_text(json.dumps({"Virtual-1": {"levels": {"3": [{"namespace": "omarchy-notifications", "x": 900, "y": 0, "w": 380, "h": 800}]}}}))
    geom = subprocess.check_output(
        ["bash", "-c", 'source "$1"; bootc_notification_layer_geometry "$2" "$3"',
         "geom-test", helper, str(m_path), str(l_path)], text=True
    ).strip()
    assert geom == "900,0 380x800", geom
    # Missing or zero-sized notification layer must fail closed.
    l_path.write_text(json.dumps({"Virtual-1": {"levels": {"3": [{"namespace": "omarchy-notifications", "x": 900, "y": 0, "w": 0, "h": 800}]}}}))
    assert subprocess.run(
        ["bash", "-c", 'source "$1"; bootc_notification_layer_geometry "$2" "$3"',
         "geom-test", helper, str(m_path), str(l_path)], capture_output=True
    ).returncode != 0

    # Cropped notification OCR succeeds when full-desktop OCR misses but measured layer matches.
    crop_bin = tmp / "bin"
    crop_bin.mkdir()
    (crop_bin / "grim").write_text('#!/usr/bin/env bash\nprintf "%s" "$*" >"${@: -1}"\n')
    (crop_bin / "tesseract").write_text(
        '#!/usr/bin/env bash\n'
        'if grep -Fq -- "-g 900,0 380x800" "$1"; then printf "Acceptance notification\\n"; else printf "desktop noise\\n"; fi\n'
    )
    (crop_bin / "omarchy-shell").write_text('#!/usr/bin/env bash\nprintf "{}"\n')
    (crop_bin / "hyprctl").write_text(
        '#!/usr/bin/env bash\n'
        'if [[ $2 == monitors ]]; then cat "$M_JSON"; else cat "$L_JSON"; fi\n'
    )
    for exe in crop_bin.iterdir():
        exe.chmod(0o755)
    l_path.write_text(json.dumps({"Virtual-1": {"levels": {"3": [{"namespace": "omarchy-notifications", "x": 900, "y": 0, "w": 380, "h": 800}]}}}))
    ocr_dir = tmp / "suite"
    ocr_dir.mkdir()
    (ocr_dir / "bootc-acceptance-helper.sh").write_bytes(script.with_name("guest-bootc-acceptance.sh").read_bytes())
    (ocr_dir / "base.sh").write_bytes(adapter.REPLACEMENTS["test/acceptance.d/base-test.sh"][1])
    art_dir = tmp / "art"
    art_dir.mkdir()
    env = dict(os.environ, PATH=str(crop_bin) + ":" + os.environ["PATH"],
               M_JSON=str(m_path), L_JSON=str(l_path))
    crop_res = subprocess.run(
        ["bash", "-c", 'set -uo pipefail; source "$1"; ARTIFACTS="$2"; screen_contains "Acceptance notification"',
         "crop-test", str(ocr_dir / "base.sh"), str(art_dir)], env=env, capture_output=True, text=True
    )
    assert crop_res.returncode == 0, crop_res.stderr
    assert "900,0 380x800" in (art_dir / "notification-ocr-crop-latest.png").read_text()

    # P1-13: duplicated first key / No matches must be rejected even though 'keybindings' is a substring.
    ocr_txt = tmp / "menu.txt"
    ocr_txt.write_text('kkeybindings\nNo matches for "kkeybindings"\n')
    assert subprocess.run(
        ["bash", "-c", 'source "$1"; bootc_validate_menu_search "$2" keybindings Keybindings',
         "menu-test", helper, str(ocr_txt)], capture_output=True
    ).returncode != 0
    ocr_txt.write_text('keybindings\nKeybindings\nLearn\n')
    assert subprocess.run(
        ["bash", "-c", 'source "$1"; bootc_validate_menu_search "$2" keybindings Keybindings',
         "menu-test", helper, str(ocr_txt)], capture_output=True
    ).returncode == 0
print("PASS: bounded six-span adaptation, preserved gates, drift refusal, root/bar/notification/menu parser boundaries (not a VM pass)")
PY
