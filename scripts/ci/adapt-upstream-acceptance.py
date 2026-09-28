#!/usr/bin/env python3
"""Adapt exactly two installer premises; never waive an upstream acceptance gate."""

import argparse
import difflib
import hashlib
import json
from pathlib import Path

REVISION = "c668141e9c42b13c80c9ca4ea108e11708c5e8a5"
# Full-suite guards deliberately require review on ANY upstream acceptance drift.
UPSTREAM_SHA256 = {
    "test/acceptance": "08773f0771e24d72687941063d4968de10a16ef81a22b554c46b785420d2fd86",
    "test/acceptance.d/apps-test.sh": "f2b4250a9f4e4d47cc08a449b8e89de8f9942a5bad54607a2159f8f53ab637ad",
    "test/acceptance.d/base-test.sh": "c74718f9ac4e322a53f172db91a5a09a7cfa615ce2c08b7c6e9e9a2c7f6f7ef8",
    "test/acceptance.d/cups-test.sh": "98cc07d62d8720c2c5b0990f192fac654b96a0bc4d22d003901e62f3b452a184",
    "test/acceptance.d/menu-test.sh": "8a181890b195de41a7830adc5ceeb23bc8863fc18cd7ff73be7fc7dcdabef98d",
    "test/acceptance.d/panels-test.sh": "1bc77bebb339a01a5c9fbacdba2e27bba1a3722b2855c051440baeafe17acc94",
    "test/acceptance.d/security-test.sh": "f1a899620c84ce45e39fc5860fbddbd26dec34e9c35c29e3518fe83f478c9400",
    "test/acceptance.d/session-test.sh": "f04af8cf2cd6e77ec8192b9eb16c8ef08967096cef1723a8e906a2cabbec4b5e",
    "test/acceptance.d/shell-surfaces-test.sh": "3d6f95297057fe7cbe7786fa073760d2d9e7a27006674fc800128b6b5717f4aa",
    "test/acceptance.d/system-test.sh": "ba02d03388c9084de57f7e7d55f666041fba16cc6c8847ab93328ed9c77965b1",
}
HELPER_PATH = "test/acceptance.d/bootc-acceptance-helper.sh"
REPLACEMENTS = {
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
        "scope": "root-filesystem-and-declared-kernel-only",
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
    print(f"Adapted exactly two assertions; patch {receipt['patch_sha256']}")


if __name__ == "__main__":
    main()
