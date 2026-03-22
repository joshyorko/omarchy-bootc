# Technical status: omarchy-bootc POC

_Last updated: 2026-03-22_

## 1) What is working today

- **Repository build structure is coherent**: numbered build scripts run from `Containerfile` and package lists are externalized for review.
- **Base image build path exists**: Arch base image, keyring init, full `pacman -Syu`, and package install layers.
- **Bootc lint gate exists**: image build runs `bootc container lint`.
- **First-boot root hook exists**: one-shot systemd service runs idempotent setup script and writes a completion stamp.
- **qcow2 conversion workflow exists**: `just build-qcow2` wraps `bootc-image-builder` invocation.

## 2) Assumptions that are plausible but unverified

These assumptions are currently required for success but still need explicit validation:

- `bootc` package behavior and long-term availability in Arch repositories.
- pacman DB relocation to `/usr/lib/sysimage/pacman` remaining compatible with update/rebase expectations.
- `bootc-image-builder` interoperability with this Arch-based image beyond simple conversion completion.
- Practical VM boot quality (graphics/session/login behavior) for the minimal Hyprland stack.

## 3) Intentionally deferred

- Full Omarchy package parity and opinionated desktop UX reproduction.
- AUR-heavy theming stack in base image build.
- BuildStream-based pipeline.
- Installer ISO/media flow.

## 4) Current risk hotspots

- **Desktop session completeness**: package presence does not yet equal a production-grade session flow.
- **Upgrade lifecycle confidence**: no documented repeated bootc rebase/rollback verification yet.
- **Host dependency variance**: local workflow depends on rootful podman, privileged containers, and KVM availability.

## 5) Next milestone (unchanged)

> Produce and validate a bootable qcow2 image in a VM.

Suggested acceptance criteria for that milestone:

1. `just build` succeeds on a clean host.
2. `just build-qcow2` produces `output/qcow2/disk.qcow2`.
3. VM boots to a reachable login/session target.
4. first-boot service completes without repeated runs.
5. At least one documented smoke test for post-boot bootc command behavior.
