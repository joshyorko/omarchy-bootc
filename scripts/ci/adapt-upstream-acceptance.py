#!/usr/bin/env python3
"""Adapt installer premises and pinned menu/bar proofs; never waive a gate."""

import argparse
import difflib
import hashlib
import json
from pathlib import Path

REVISION = "ac2690cd7be4f47e4a255f5e2e78d904d436b068"
# Full-suite guards deliberately require review on ANY upstream acceptance drift.
UPSTREAM_SHA256 = {
    "test/acceptance": "08773f0771e24d72687941063d4968de10a16ef81a22b554c46b785420d2fd86",
    "test/acceptance.d/apps-test.sh": "f2b4250a9f4e4d47cc08a449b8e89de8f9942a5bad54607a2159f8f53ab637ad",
    "test/acceptance.d/base-test.sh": "66177a7ba966eb6a552fb76f3e600442ff07988757d7db5a12c193b945679aaa",
    "test/acceptance.d/cups-test.sh": "98cc07d62d8720c2c5b0990f192fac654b96a0bc4d22d003901e62f3b452a184",
    "test/acceptance.d/input-method-notifications.py": "d715f84284c594396eceb1f7c4a02ebbb2e730fbbaede11375d33297d67a3c9a",
    "test/acceptance.d/input-method-state.py": "19510ad3263efdaea02c9b7a6a2a6ea266e3ad8fd2368187714d9d22ff39a0c6",
    "test/acceptance.d/input-methods-test.sh": "4bd143706dc5db76c310ad8e03979adc235c67b9fd8e72c3d57c2bc3377b3734",
    "test/acceptance.d/menu-test.sh": "90113adc1702ed96d7af22b1a290388c3a9f79566bab7f86f394fa96157cc225",
    "test/acceptance.d/overlay-monitor-test.sh": "bfc109915e7de1ce3428cb724a301105c4f1b3a5f465a38312ba55f9a014e26f",
    "test/acceptance.d/panels-test.sh": "1bc77bebb339a01a5c9fbacdba2e27bba1a3722b2855c051440baeafe17acc94",
    "test/acceptance.d/security-test.sh": "f1a899620c84ce45e39fc5860fbddbd26dec34e9c35c29e3518fe83f478c9400",
    "test/acceptance.d/session-test.sh": "f04af8cf2cd6e77ec8192b9eb16c8ef08967096cef1723a8e906a2cabbec4b5e",
    "test/acceptance.d/shell-surfaces-test.sh": "2d7fb57ae0b5682473ecb7c1420cfde08c1d5f622993d093671ebd00715f1b97",
    "test/acceptance.d/system-test.sh": "ba02d03388c9084de57f7e7d55f666041fba16cc6c8847ab93328ed9c77965b1",
}
HELPER_PATH = "test/acceptance.d/bootc-acceptance-helper.sh"
REPLACEMENTS = {
    # The pinned menu has Apps, Learn, Appearance, Trigger. Three Down keys
    # select Trigger, not Appearance. Menu Bar is the fourth appearance item;
    # Position follows Hide/Show Bar. Preserve every assertion and screenshot.
    # Its transparent bar layer spans the screen; prove orientation by the
    # compositor-reserved edge, with the bar present on that same monitor.
    "test/acceptance.d/menu-test.sh": (
        b'''bar_is_vertical() {
  local width height

  read -r width height < <(hyprctl -j layers | jq -r '
    [.. | objects | select(.namespace? == "omarchy-bar")][0]
    | [.w, .h] | @tsv
  ')

  [[ $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ ]] && ((width < height))
}

bar_is_horizontal() {
  local width height

  read -r width height < <(hyprctl -j layers | jq -r '
    [.. | objects | select(.namespace? == "omarchy-bar")][0]
    | [.w, .h] | @tsv
  ')

  [[ $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ ]] && ((width > height))
}

bar_position_is() {
  local expected="$1"

  [[ $(jq -r '.bar.position // "top"' "$CONFIG_FILE") == $expected ]]
}

source_file=$DEFAULTS_FILE
((config_existed)) && source_file=$CONFIG_FILE
original_position=$(jq -r '.bar.position // "top"' "$source_file")

omarchy-shell shell summon omarchy.menu '{"menu":"root"}' >/dev/null
wait_until "root menu opens" 15 layer_on_overlay "omarchy-menu"
wait_until "root menu content is visible" 15 screen_contains "Apps"
screenshot "success-menu-01-root"

wtype -k Down -k Down -k Down
sleep 1
screenshot "success-menu-02-style-selected"
wtype -k Return

wait_until "style submenu is visible" 15 screen_contains "Theme"
screenshot "success-menu-03-style-submenu"

wtype -k Down -k Down -k Down -k Down -k Return
sleep 1
screenshot "success-menu-04-menu-bar-submenu"

wtype -k Return
sleep 1
screenshot "success-menu-05-position-submenu"

wtype -k Down -k Down -k Return
''',
        b'''bar_is_vertical() {
  bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bootc-acceptance-helper.sh" bar-vertical
}

bar_is_horizontal() {
  bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bootc-acceptance-helper.sh" bar-horizontal
}

bar_position_is() {
  local expected="$1"

  [[ $(jq -r '.bar.position // "top"' "$CONFIG_FILE") == $expected ]]
}

source_file=$DEFAULTS_FILE
((config_existed)) && source_file=$CONFIG_FILE
original_position=$(jq -r '.bar.position // "top"' "$source_file")

omarchy-shell shell summon omarchy.menu '{"menu":"root"}' >/dev/null
wait_until "root menu opens" 15 layer_on_overlay "omarchy-menu"
wait_until "root menu content is visible" 15 screen_contains "Apps"
screenshot "success-menu-01-root"

wtype -k Down -k Down
sleep 1
screenshot "success-menu-02-style-selected"
wtype -k Return

wait_until "style submenu is visible" 15 screen_contains "Theme"
screenshot "success-menu-03-style-submenu"

wtype -k Down -k Down -k Down -k Return
sleep 1
screenshot "success-menu-04-menu-bar-submenu"

wtype -k Down -k Return
sleep 1
screenshot "success-menu-05-position-submenu"

wtype -k Down -k Down -k Return
''',
    ),
    "test/acceptance.d/session-test.sh": (
        b'''# Root filesystem is btrfs as installed
[[ $(findmnt -no FSTYPE /) == "btrfs" ]] || fail "root filesystem is btrfs"
pass "root filesystem is btrfs"
''',
        b'''# bootc architecture: immutable composefs root on the installed Btrfs backing.
bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bootc-acceptance-helper.sh" root ||
  fail "immutable composefs root has Btrfs backing and booted identity"
''',
    ),
    "test/acceptance.d/system-test.sh": (
        b'''verify_kernel_headers() {
  local kernel=linux-omarchy
  local release
  release=$(uname -r)
  omarchy-pkg-present linux-t2 && kernel=linux-t2

  [[ $(cat "/usr/lib/modules/$release/pkgbase") == "$kernel" ]] ||
    fail "the installed system boots the supported kernel" "$release is not $kernel"
  omarchy-pkg-present "$kernel-headers" || fail "kernel headers are installed" "$kernel-headers is missing"
  [[ $(cat "/usr/lib/modules/$release/build/include/config/kernel.release") == "$release" ]] ||
    fail "headers match the running kernel" "$release has missing or mismatched headers"
  pass "the running $kernel kernel has matching headers ($release)"
}
''',
        b'''verify_kernel_headers() {
  # bootc architecture: the image declares the supported kernel, not the installer.
  bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bootc-acceptance-helper.sh" kernel ||
    fail "the running image-declared kernel has package-owned matching headers"
}
''',
    ),
}


def sha256(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def adapt(root, revision, artifacts):
    if revision != REVISION:
        raise ValueError(f"unsupported upstream revision: {revision}")
    for directory in (root / "test", root / "test/acceptance.d"):
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError(f"not a real suite directory: {directory}")
    actual = {"test/acceptance"} | {
        p.relative_to(root).as_posix() for p in (root / "test/acceptance.d").iterdir()
    }
    if actual != set(UPSTREAM_SHA256):
        raise ValueError("upstream acceptance inventory drift (missing or extra files)")
    original = {}
    for name, expected in UPSTREAM_SHA256.items():
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"not a regular upstream file: {name}")
        original[name] = path.read_bytes()
        if hashlib.sha256(original[name]).hexdigest() != expected:
            raise ValueError(f"upstream checksum drift: {name}")
    adapted = dict(original)
    changes = []
    for name, (old, new) in REPLACEMENTS.items():
        if original[name].count(old) != 1:
            raise ValueError(f"upstream assertion snippet drift: {name}")
        adapted[name] = original[name].replace(old, new, 1)
        changes.append({"path": name, "before_sha256": sha256(original[name]),
                        "after_sha256": sha256(adapted[name]),
                        "original": old.decode(), "replacement": new.decode()})
    helper = Path(__file__).with_name("guest-bootc-acceptance.sh").read_bytes()
    adapted[HELPER_PATH] = helper
    patch = b""
    for name in (*REPLACEMENTS, HELPER_PATH):
        patch += b"".join(difflib.diff_bytes(
            difflib.unified_diff, original.get(name, b"").splitlines(keepends=True),
            adapted[name].splitlines(keepends=True),
            fromfile=("a/" + name).encode() if name in original else b"/dev/null",
            tofile=("b/" + name).encode(),
        ))
    # Validate everything before touching the staged suite or issuing a receipt.
    artifacts.mkdir(parents=True, exist_ok=True)
    for name in (*REPLACEMENTS, HELPER_PATH):
        (root / name).write_bytes(adapted[name])
    patch_name = "upstream-acceptance-adaptation.patch"
    (artifacts / patch_name).write_bytes(patch)
    receipt = {
        "schema": "omarchy-bootc.upstream-acceptance-adaptation/v1",
        "upstream_revision": revision,
        "status": "adapted-not-executed",
        "scope": "root-filesystem-declared-kernel-menu-navigation-and-bar-reservations",
        "changes": changes,
        "helper": {"path": HELPER_PATH, "sha256": sha256(helper)},
        "patch": patch_name,
        "patch_sha256": sha256(patch),
        "original_sha256": {p: sha256(b) for p, b in original.items()},
        "adapted_sha256": {p: sha256(b) for p, b in adapted.items()},
        "required_tests": sorted(p for p in original
                                 if p.endswith("-test.sh") and not p.endswith("/base-test.sh")),
        "skipped_tests": [],
    }
    (artifacts / "upstream-acceptance-adaptation.json").write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n"
    )
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-root", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--artifacts", required=True, type=Path)
    args = parser.parse_args()
    try:
        receipt = adapt(args.upstream_root, args.revision, args.artifacts)
    except (OSError, ValueError) as error:
        parser.exit(1, f"acceptance adaptation refused: {error}\n")
    print(f"Adapted {len(receipt['changes'])} recorded spans; patch {receipt['patch_sha256']}")


if __name__ == "__main__":
    main()
