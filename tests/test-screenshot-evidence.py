#!/usr/bin/env python3
"""Provenance/index behavior only; no VM or acceptance pixels are synthesized."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("evidence", Path(__file__).resolve().parents[1] / "scripts/ci/record-screenshot-evidence.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)
with tempfile.TemporaryDirectory(prefix="codex-screenshot-metadata-", dir="/tmp") as temp:
    root = Path(temp)
    (root / "screenshots").mkdir()
    path = root / "screenshots/observed.png"
    data = b"\x89PNG\r\n\x1a\n" + b"\0" * 8 + struct.pack(">II", 123, 456)
    path.write_bytes(data)
    env = dict(GITHUB_REPOSITORY="owner/repo", GITHUB_RUN_ID="42", INSTALL_IMAGE_REF="repo@sha256:" + "a" * 64,
               INSTALL_SOURCE_SHA="b" * 40, GITHUB_SHA="c" * 40, ISO_SHA256="d" * 64, CI_JOB_ID="99", GITHUB_JOB="installer-acceptance")
    with patch.dict(os.environ, env):
        evidence.record(path, "Observed installer frame, not a page assertion", "installer")
        entry = json.loads(path.with_suffix(".json").read_text())
        assert entry["sha256"] == hashlib.sha256(data).hexdigest()
        assert entry["dimensions"] == [123, 456] and entry["source_sha"] == "b" * 40
        assert entry["harness_sha"] == "c" * 40 and entry["iso_digest"] == "sha256:" + "d" * 64
        assert entry["job_url"].endswith("/runs/42/job/99") and entry["captured_at"].endswith("+00:00")
        assert entry["reviewed_for_publication"] is False and "pending" in entry["outcome"]
        assert "ISO live guest" in entry["provenance"]
        evidence.index(root, "failed")
        manifest = json.loads((root / "screenshot-manifest.json").read_text())
        assert manifest["status"] == "failed" and len(manifest["screenshots"]) == 1
        assert manifest["screenshots"][0]["acceptance_command_status"] == "failed"
        assert "bypasses" in manifest["not_captured"][0] and "not shown" in manifest["not_captured"][1]
        assert "Visual review remains required" in (root / "screenshot-index.md").read_text()
        evidence.record(path, "Disk-only desktop", "installed")
        entry = json.loads(path.with_suffix(".json").read_text())
        assert "disk-only KVM guest; no overlay" in entry["provenance"]
        assert path.read_bytes() == data
        path.write_text("not a PNG")
        try:
            evidence.record(path, "invalid", "installed")
        except ValueError:
            pass
        else:
            raise AssertionError("Accepted non-PNG")
print("PASS: immutable pixels, phase/source/ISO/hash/job/time provenance, unreviewed status and honest missing-stage index (not VM acceptance)")
