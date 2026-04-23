# Repository Guidelines

## Project Structure & Module Organization
`Containerfile` builds the Arch-based bootc image and runs the numbered build stages in `build/` (`10-base.sh`, `20-omarchy.sh`, `30-services.sh`). Keep new image customization in those scripts, not inline in the container build. Package manifests live in `custom/packages/`. Desktop and first-boot assets live under `custom/` (`hypr/`, `greetd/`, `first-boot/`). VM and CI smoke coverage lives in `scripts/ci/vm-smoke.sh`. Systemd units belong in `systemd/system/`. Use `docs/` for design notes and status tracking, and treat `output/` as generated build artifacts only.

## Build, Test, and Development Commands
Run `just help` to see the supported workflows. Use `just validate` before longer runs; it checks required tools, expected files, and warns if `/dev/kvm` is missing. `just build` builds `localhost/omarchy-bootc:stable`. `just build-qcow2` converts that image into `output/qcow2/disk.qcow2`, and `just run-vm` boots it locally. For legacy fallback testing, use `just build-qcow2-bib`. Use `just lint` for `shellcheck` and `just format` for `shfmt`.

## Coding Style & Naming Conventions
Shell is the dominant language here. Write Bash with `#!/usr/bin/env bash` or `#!/usr/bin/bash`, enable `set -euo pipefail` unless a script intentionally needs tracing, and keep `shellcheck` clean. Match existing indentation and keep multi-line commands readable. Preserve the numbered `build/*.sh` ordering for image stages. Prefer lowercase, hyphenated filenames such as `vm-smoke.sh`, and keep package list names aligned with their scope (`base.packages`, `omarchy.packages`).

## Testing Guidelines
There is no separate unit-test tree today; validation is task-based. Minimum check for most changes: `just validate && just lint`. If you touch image build logic, run `just build`. If you change boot flow, packages, or systemd behavior, also run `scripts/ci/vm-smoke.sh localhost/omarchy-bootc:stable` or `just build-qcow2 && just run-vm`. Note whether testing used KVM or software emulation.

## Commit & Pull Request Guidelines
Recent history uses short, imperative subjects such as `Fix inaccessible KVM fallback in VM smoke test`, with occasional prefixes like `feat:`, `[codex]`, or `[WIP]`. Keep the first line specific to the affected path or behavior. PRs should explain user-visible image changes, call out host requirements (`podman`, `sudo`, `/dev/kvm`, `machinectl`), and include relevant logs or artifact paths when the VM smoke path changes.
