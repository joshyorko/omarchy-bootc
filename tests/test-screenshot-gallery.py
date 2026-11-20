#!/usr/bin/env python3
"""Offline publication-boundary tests; fixture pixels are never acceptance evidence."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("gallery", Path(__file__).resolve().parents[1] / "scripts/ci/publish-screenshot-gallery.py")
gallery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gallery)
with tempfile.TemporaryDirectory(prefix="codex-gallery-", dir="/tmp") as temp:
    root = Path(temp)
    # Only the metadata parser is exercised, not a display/PNG-rendering gate.
    data = b"\x89PNG\r\n\x1a\n" + b"\0" * 8 + struct.pack(">II", 10, 20)
    (root / "test.png").write_bytes(data)
    entry = dict(path="test.png", sha256=hashlib.sha256(data).hexdigest(), dimensions=[10, 20],
                 stage="fixture", source_sha="a" * 40, image_digest="sha256:" + "b" * 64,
                 iso_digest=None, run_url="run", job_url="job", artifact_url="artifact",
                 artifact_member="screenshots/test.png", provenance="test only", step="test",
                 outcome="not acceptance", reviewed_for_publication=True, group="fixture")
    manifest = dict(scope="test only", screenshots=[entry], not_captured=["ISO"])
    assert gallery.checked_files(root, manifest) == {"test.png": data}
    for field, value in [("sha256", "0" * 64), ("dimensions", [1, 2]), ("reviewed_for_publication", False),
                         ("path", "../test.png"), ("source_sha", "main"), ("image_digest", ":testing")]:
        invalid = copy.deepcopy(manifest)
        invalid["screenshots"][0][field] = value
        try:
            gallery.checked_files(root, invalid)
        except ValueError:
            pass
        else:
            raise AssertionError(f"Accepted invalid {field}")
    linked = root / "escape.png"
    linked.symlink_to("/etc/passwd")
    invalid = copy.deepcopy(manifest)
    invalid["screenshots"][0]["path"] = "escape.png"
    try:
        gallery.checked_files(root, invalid)
    except ValueError:
        pass
    else:
        raise AssertionError("Accepted symlink escape")
    path = root / "manifest.json"
    path.write_text(json.dumps(manifest))
    with patch.object(sys, "argv", ["gallery", str(path)]), patch.object(gallery, "api") as transport, contextlib.redirect_stdout(io.StringIO()):
        gallery.main()
        transport.assert_not_called()
    for existing in (False, True):
        calls = []
        def api(repository, endpoint, payload=None):
            calls.append((endpoint, payload))
            if endpoint == "":
                return {"visibility": "public"}
            if endpoint.startswith("git/matching-refs"):
                return [{"ref": "refs/heads/evidence/acceptance-gallery", "object": {"sha": "parent"}}] if existing else []
            return {"sha": "c" * 40}
        with patch.object(sys, "argv", ["gallery", str(path), "--publish"]), patch.object(gallery, "api", side_effect=api), patch.object(gallery.subprocess, "run") as transport, contextlib.redirect_stdout(io.StringIO()):
            gallery.main()
            commit = next(payload for endpoint, payload in calls if endpoint == "git/commits")
            assert commit["parents"] == (["parent"] if existing else [])
            if existing:
                assert json.loads(transport.call_args.kwargs["input"])["force"] is False
            else:
                transport.assert_not_called()
        text = (root / "published-gallery.md").read_text()
        assert "![fixture](https://raw.githubusercontent.com/" in text
        assert "NOT CAPTURED" in text and "not acceptance" in text
    with patch.object(sys, "argv", ["gallery", str(path), "--publish"]), patch.object(gallery, "api", return_value={"visibility": "private"}) as transport:
        try:
            gallery.main()
        except ValueError:
            pass
        else:
            raise AssertionError("Accepted private repository without public URLs")
        assert transport.call_count == 1
print("PASS: explicit publication, provenance/hash/dimension/path review, public raw URLs and non-forced evidence-only refs (not guest acceptance)")
