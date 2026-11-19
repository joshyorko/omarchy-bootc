#!/usr/bin/env python3
"""Bind a reusable artifact to a trusted Actions producer before privileged use."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import urllib.request

REPOSITORY = "joshyorko/omarchy-bootc"
PRODUCERS = {
    ".github/workflows/candidate.yml": "Build exact-head candidate",
    ".github/workflows/dagger-parity.yml": "dagger",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def instant(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def validate(run, workflow, jobs, artifacts, run_id, head):
    require(run.get("id") == run_id, "run identity mismatch")
    require(run.get("head_sha") == head, "producer head SHA differs from candidate")
    require(run.get("repository", {}).get("full_name") == REPOSITORY, "foreign producer repository")
    require(run.get("head_repository", {}).get("full_name") == REPOSITORY, "foreign producer head repository")
    path = run.get("path", "").split("@", 1)[0]
    require(path in PRODUCERS, "unapproved producing workflow")
    require(workflow.get("id") == run.get("workflow_id") and workflow.get("path") == path,
            "workflow metadata mismatch")
    build_jobs = [job for job in jobs if job.get("name") == PRODUCERS[path]]
    require(len(build_jobs) == 1 and build_jobs[0].get("conclusion") == "success",
            "candidate build job did not succeed uniquely")
    build = build_jobs[0]
    require(build.get("run_id") == run_id and build.get("head_sha") == head,
            "build job identity mismatch")
    name = f"omarchy-bootc-candidate-{head}"
    selected = [artifact for artifact in artifacts if artifact.get("name") == name]
    require(len(selected) == 1, "candidate artifact missing or ambiguous")
    artifact = selected[0]
    require(isinstance(artifact.get("id"), int) and artifact["id"] > 0, "invalid artifact ID")
    require(not artifact.get("expired", True) and artifact.get("size_in_bytes", 0) > 0,
            "artifact expired or empty")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")),
            "missing immutable Actions artifact digest")
    producer = artifact.get("workflow_run", {})
    require(producer.get("id") == run_id and producer.get("head_sha") == head,
            "artifact producer/head mismatch")
    require(producer.get("repository_id") == run["repository"]["id"] and
            producer.get("head_repository_id") == run["repository"]["id"],
            "artifact repository identity mismatch")
    require(instant(build["started_at"]) <= instant(artifact["created_at"]) <= instant(build["completed_at"]),
            "artifact was not created during the successful build job")
    return {"schema": "omarchy-bootc.actions-producer/v1", "repository": REPOSITORY,
            "source_head": head, "run_id": run_id, "run_attempt": run["run_attempt"],
            "workflow": path, "workflow_id": run["workflow_id"], "build_job_id": build["id"],
            "artifact_id": artifact["id"], "artifact_name": name, "artifact_digest": artifact["digest"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id", type=int)
    parser.add_argument("head")
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    require(args.run_id > 0 and re.fullmatch(r"[0-9a-f]{40}", args.head), "invalid candidate identity")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    require(bool(token), "Actions read token is required")

    def get(endpoint):
        request = urllib.request.Request("https://api.github.com/repos/" + REPOSITORY + endpoint,
            headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def pages(endpoint, key):
        result = []
        for page in range(1, 101):
            items = get(endpoint + f"?per_page=100&page={page}")[key]
            result.extend(items)
            if len(items) < 100:
                return result
        raise ValueError("producer inventory exceeds bounded pagination")

    run = get(f"/actions/runs/{args.run_id}")
    workflow = get(f"/actions/workflows/{run['workflow_id']}")
    jobs = pages(f"/actions/runs/{args.run_id}/attempts/{run['run_attempt']}/jobs", "jobs")
    artifacts = pages(f"/actions/runs/{args.run_id}/artifacts", "artifacts")
    # Fetch the selected artifact by immutable ID, not just a matching name.
    name = f"omarchy-bootc-candidate-{args.head}"
    artifacts = [get(f"/actions/artifacts/{a['id']}") for a in artifacts if a.get("name") == name]
    receipt = validate(run, workflow, jobs, artifacts, args.run_id, args.head)
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"artifact_id={receipt['artifact_id']}\n")
    print(f"Verified producer run {args.run_id}, artifact {receipt['artifact_id']}, source {args.head}")


if __name__ == "__main__":
    main()
