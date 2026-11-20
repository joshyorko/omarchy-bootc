#!/usr/bin/env python3
"""Record provenance beside unmodified guest pixels; never certify acceptance."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import struct


def record(path, stage, phase):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Expected actual QMP PNG")
    env = os.environ
    repository = env["GITHUB_REPOSITORY"]
    run = env["GITHUB_RUN_ID"]
    ref = env["INSTALL_IMAGE_REF"]
    entry = dict(path="screenshots/" + path.name, stage=stage, phase=phase,
                 captured_at=datetime.now(timezone.utc).isoformat(),
                 source_sha=env["INSTALL_SOURCE_SHA"], harness_sha=env["GITHUB_SHA"],
                 image_digest=ref.rsplit("@", 1)[1], install_image_ref=ref,
                 iso_digest="sha256:" + env["ISO_SHA256"],
                 run_url=f"https://github.com/{repository}/actions/runs/{run}",
                 job_url=f"https://github.com/{repository}/actions/runs/{run}/job/{env['CI_JOB_ID']}",
                 job_name=env["GITHUB_JOB"], step="Install the ISO on a blank disk and log into the installed desktop",
                 provenance="actual ISO live guest" if phase == "installer" else "actual installed disk-only KVM guest; no overlay",
                 outcome="captured; acceptance and visual review pending", reviewed_for_publication=False,
                 sha256=hashlib.sha256(data).hexdigest(), size_bytes=len(data),
                 dimensions=list(struct.unpack(">II", data[16:24])))
    path.with_suffix(".json").write_text(json.dumps(entry, indent=2) + "\n")


def index(root, status):
    entries = [json.loads(path.read_text()) for path in sorted((root / "screenshots").glob("*.json"))]
    for entry in entries:
        entry["acceptance_command_status"] = status
    unavailable = ["GRUB: direct-kernel ISO boot bypasses its menu.",
                   "Interactive disk selection/account creation: supplied by disposable kickstart, not shown.",
                   "Anaconda landing/progress/completion: label only after actual frame review; numbered observations are not proof of a particular page.",
                   "Update B/rollback A: separate OS qualification, not exercised by this installer test."]
    notes = root / "capture-notes.txt"
    if notes.exists():
        unavailable.extend(notes.read_text().splitlines())
    manifest = dict(schema="omarchy.iso-screenshots/v1", scope="Blank-disk Anaconda ISO installation; raw QMP frames, no synthetic or historical substitutions.",
                    status=status, screenshots=entries, not_captured=unavailable)
    (root / "screenshot-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    lines = ["# Actual ISO/installed-guest frames", "", f"Acceptance command: {status}. Visual review remains required.", ""]
    for entry in entries:
        lines += [f"## {entry['stage']}", "", f"![{entry['stage']}]({entry['path']})", "",
                  f"{entry['provenance']}; {entry['captured_at']}. Source `{entry['source_sha']}`; image `{entry['image_digest']}`; ISO `{entry['iso_digest']}`.", "",
                  f"[Job]({entry['job_url']}). PNG SHA256 `{entry['sha256']}`. Outcome: {entry['outcome']}.", ""]
    lines += ["## Not captured", ""] + ["- " + item for item in unavailable]
    (root / "screenshot-index.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("record")
    capture.add_argument("path", type=Path)
    capture.add_argument("stage")
    capture.add_argument("phase", choices=["installer", "installed"])
    summary = commands.add_parser("index")
    summary.add_argument("root", type=Path)
    summary.add_argument("status", choices=["failed", "installed-guest-checks-passed"])
    args = parser.parse_args()
    if args.command == "record":
        record(args.path, args.stage, args.phase)
    else:
        index(args.root, args.status)
