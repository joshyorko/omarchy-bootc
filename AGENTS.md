# Repository Guidelines

## Project Structure & Module Organization
`Containerfile` defines the Arch bootc build graph: `stable-base -> bootcrew-system -> quattro-assembly -> quattro-base -> quattro-integration -> final`; `foundation` is a sibling verification target. See `build/README.md` for effective scripts and dependency phases. Package authority is the effective foundation package command and the official Omarchy package's embedded manifests, not local `custom/packages/` lists. Runtime adapters live under `custom/bootc/` and `custom/first-boot/`; systemd units belong in `systemd/system/`. VM and CI coverage lives in `scripts/ci/`. Treat `output/` as generated artifacts.

## Build, Test, and Development Commands
Run `just help` to see the supported workflows. Use `just validate` before longer runs; it checks required tools, expected files, and warns if `/dev/kvm` is missing. `just build` builds `localhost/omarchy-bootc:stable`. `just build-qcow2` converts that image into `output/qcow2/disk.qcow2`, and `just run-vm` boots it locally. For legacy fallback testing, use `just build-qcow2-bib`. Use `just lint` for `shellcheck` and `just format` for `shfmt`.

## Coding Style & Naming Conventions
Shell is the dominant language here. Write Bash with `#!/usr/bin/env bash` or `#!/usr/bin/bash`, enable `set -euo pipefail` unless a script intentionally needs tracing, and keep `shellcheck` clean. Match existing indentation and keep multi-line commands readable. Wire image changes into the effective Containerfile ancestry; numbered filenames do not imply execution. Prefer lowercase, hyphenated filenames such as `vm-smoke.sh`.

## Testing Guidelines
Behavior and architecture-policy regressions live in `tests/`. Run focused regressions and dependency preflight before costly runtime acceptance. In coordinated edits, integrate all workers first, then run validation once; do not build, lint, test or format half-integrated changes. Source policy checks do not certify an image: run the installed `acceptance-dependencies.sh` for the exact final, disposable overlay and provisioned guest, and retain actual VM/update/rollback receipts. Never use the acceptance image as the publishable product. Note whether runtime testing used KVM or software emulation.

## Commit & Pull Request Guidelines
Recent history uses short, imperative subjects such as `Fix inaccessible KVM fallback in VM smoke test`, with occasional prefixes like `feat:`, `[codex]`, or `[WIP]`. Keep the first line specific to the affected path or behavior. PRs should explain user-visible image changes, call out host requirements (`podman`, `sudo`, `/dev/kvm`, `machinectl`), and include relevant logs or artifact paths when the VM smoke path changes.
