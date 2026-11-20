#!/usr/bin/env python3
"""Publish explicitly reviewed PNG evidence, never build images or qualify a VM."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


def api(repository, endpoint, payload=None):
    command = ["gh", "api", f"repos/{repository}/{endpoint}".rstrip("/")]
    if payload is not None:
        command += ["--method", "POST", "--input", "-"]
    result = subprocess.run(command, input=None if payload is None else json.dumps(payload),
                            text=True, capture_output=True, check=True, timeout=90)
    return json.loads(result.stdout)


def checked_files(root, manifest):
    files = {}
    for entry in manifest["screenshots"]:
        relative = Path(entry["path"])
        path = (root / relative).resolve()
        if relative.is_absolute() or ".." in relative.parts or not path.is_relative_to(root):
            raise ValueError("Screenshot escapes evidence root")
        data = path.read_bytes()
        if len(data) > 16 * 1024 * 1024 or data[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError("Expected a bounded raw PNG")
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError("Screenshot hash mismatch")
        if list(struct.unpack(">II", data[16:24])) != entry["dimensions"]:
            raise ValueError("Screenshot dimensions mismatch")
        for field in ("stage", "source_sha", "image_digest", "iso_digest", "run_url", "job_url",
                      "artifact_url", "artifact_member", "provenance", "step", "outcome"):
            if field not in entry:
                raise ValueError(f"Missing screenshot provenance: {field}")
        if not re.fullmatch(r"[0-9a-f]{40}", entry["source_sha"]):
            raise ValueError("Expected exact source SHA")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", entry["image_digest"]):
            raise ValueError("Expected exact image digest")
        if entry.get("reviewed_for_publication") is not True:
            raise ValueError("Screenshot requires explicit publication review")
        files[relative.as_posix()] = data
    if not files or len(files) != len(manifest["screenshots"]):
        raise ValueError("Expected unique reviewed screenshots")
    if sum(map(len, files.values())) > 100 * 1024 * 1024:
        raise ValueError("Gallery exceeds 100 MiB publication budget")
    return files


def markdown(manifest, repository, commit):
    raw = f"https://raw.githubusercontent.com/{repository}/{commit}"
    lines = ["<!-- acceptance-gallery:start -->", "## Real guest screenshot gallery", "",
             manifest["scope"], "", f"[Full-resolution PNGs and provenance manifest](https://github.com/{repository}/tree/{commit})", ""]
    for group in dict.fromkeys(e["group"] for e in manifest["screenshots"]):
        lines += [f"### {group}", ""]
        for entry in manifest["screenshots"]:
            if entry["group"] != group:
                continue
            lines += [f"**{entry['stage']}** — {entry['provenance']}; {entry['outcome']}.", "",
                      f"![{entry['stage']}]({raw}/{entry['path']})", "",
                      f"Source `{entry['source_sha']}` · image `{entry['image_digest']}` · ISO `{entry['iso_digest'] or 'not used'}`.", "",
                      f"[Run]({entry['run_url']}) · [job]({entry['job_url']}) · [raw artifact]({entry['artifact_url']}) · [receipt/index]({raw}/manifest.json). Step: {entry['step']}. SHA256 `{entry['sha256']}`.", ""]
    lines += ["### Not captured / not qualified", ""]
    lines += [f"- **NOT CAPTURED:** {stage}" for stage in manifest.get("not_captured", [])]
    lines += ["", "<!-- acceptance-gallery:end -->", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--publish", action="store_true", help="Explicitly upload reviewed evidence to the public repository")
    parser.add_argument("--repository", default="joshyorko/omarchy-bootc")
    parser.add_argument("--branch", default="evidence/acceptance-gallery")
    args = parser.parse_args()
    root = args.manifest.resolve().parent
    manifest = json.loads(args.manifest.read_text())
    files = checked_files(root, manifest)
    if not args.publish:
        print(f"Validated {len(files)} reviewed PNGs ({sum(map(len, files.values()))} bytes); nothing uploaded")
        return
    if api(args.repository, "")["visibility"] != "public":
        raise ValueError("Public image URLs require an explicitly public repository")
    refs = api(args.repository, f"git/matching-refs/heads/{args.branch}")
    refs = [ref for ref in refs if ref["ref"] == f"refs/heads/{args.branch}"]
    parent = refs[0]["object"]["sha"] if refs else None
    files["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    tree_entries = []
    for name, data in files.items():
        blob = api(args.repository, "git/blobs", {"content": base64.b64encode(data).decode(), "encoding": "base64"})
        tree_entries.append({"path": name, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    # A complete evidence-only tree; no product ancestry or workflow files.
    tree = api(args.repository, "git/trees", {"tree": tree_entries})
    commit = api(args.repository, "git/commits", {"message": "Retain reviewed real KVM screenshot evidence", "tree": tree["sha"], "parents": [parent] if parent else []})
    if parent:
        # Non-forced update rejects concurrent changes rather than losing evidence.
        command = ["gh", "api", f"repos/{args.repository}/git/refs/heads/{args.branch}", "--method", "PATCH", "--input", "-"]
        subprocess.run(command, input=json.dumps({"sha": commit["sha"], "force": False}), text=True, capture_output=True, check=True, timeout=90)
    else:
        api(args.repository, "git/refs", {"ref": f"refs/heads/{args.branch}", "sha": commit["sha"]})
    (root / "published-gallery.md").write_text(markdown(manifest, args.repository, commit["sha"]))
    (root / "publication.json").write_text(json.dumps({"repository": args.repository, "branch": args.branch, "commit": commit["sha"], "screenshots": len(manifest["screenshots"]), "bytes": sum(map(len, files.values()))}, indent=2) + "\n")
    print(f"Published {len(manifest['screenshots'])} real PNGs at {commit['sha']}")


if __name__ == "__main__":
    main()
