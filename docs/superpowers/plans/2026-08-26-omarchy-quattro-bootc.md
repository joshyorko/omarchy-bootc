# Omarchy Quattro on bootc Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify official Omarchy Quattro v4.0.1 on an empty-root Omarchy-stable Arch package universe using pinned Bootcrew bootc construction.

**Architecture:** Use current Arch only as a pinned disposable pacman tool, populate an empty root from Omarchy stable, and apply Bootcrew mono commit `5f048fa…` there. Build bootc commit `3e76c165…` inside that stable root, then install the official signed Quattro closure and isolate only demonstrated Limine/mkinitcpio/Snapper collisions.

**Tech Stack:** Containerfile, Bash, pacman, systemd, bootc, dracut, Podman, QEMU/KVM.

**Spec:** `docs/superpowers/specs/2026-08-26-omarchy-quattro-bootc-design.md`

## Global Constraints

- Do not inherit the published rolling Bootcrew image.
- Use Bootcrew mono construction commit `5f048fa65a94daefc814d3cdd941d8d1e113c09e`.
- Build bootc from commit `3e76c16556c55e6d15d31bd47602b231e2131cb2`.
- Resolve the final root from an empty filesystem against Omarchy stable; never use `pacman -Syyuu` to downgrade a prebuilt root.
- Use official Omarchy v4.0.1 packages from source commit `13f18b2cb7286fb54f87daf571a031aa6af3d8f0`.
- Use `omacom-io/omarchy-iso` Quattro commit `268bac16d351a21d867e37565738f458b11cb06c` as the installer UX and acceptance reference.
- Do not modify or wrap an `omarchy-*` command.
- Bootc exclusively owns deployment, `/boot`, initramfs, upgrade, and rollback.
- Neutralize only evidenced Limine/mkinitcpio/Snapper collisions.
- Do not implement `omarchy update` integration until desktop and bootc lifecycle acceptance pass; read-only source reconstruction remains separate.
- Preserve every existing Dudley, Dakota, and Bluefin prescribed installer; the Quattro installer is an additive variant.

---

### Task 1: Executable source contract

**Files:**
- Create: `tests/test-quattro-source-contract.sh`
- Modify: `Justfile`

**Interfaces:**
- Consumes: the immutable inputs in the design spec.
- Produces: `just test-contract`, a fast local gate used by every later task.

- [ ] Write `tests/test-quattro-source-contract.sh` to execute the Containerfile and build scripts against controlled fixtures and assert the Bootcrew digest, Quattro version, package versions, upstream manifest paths, absence of wrapper payloads, and boot-owner mask list.
- [ ] Run `bash tests/test-quattro-source-contract.sh`; expect failure against the prior rolling-Arch, homemade-desktop POC.
- [ ] Add `test-contract` to `Justfile` and the minimum production files required by the assertions.
- [ ] Run `just test-contract`; expect success.
- [ ] Run `just validate && just lint`.

### Task 2: Omarchy-stable Bootcrew foundation and official Quattro installation

**Files:**
- Modify: `Containerfile`
- Create: `build/configure-quattro-repositories.sh`
- Create: `vendor/bootcrew/REVISION`
- Create: `vendor/bootcrew/BOOTC_REVISION`
- Create: `vendor/bootcrew/shared/build.sh`
- Create: `vendor/bootcrew/shared/initramfs.sh`
- Create: `vendor/bootcrew/shared/bootc-rootfs.sh`
- Create: `build/20-quattro.sh`
- Create: `build/25-quattro-user.sh`
- Create: `custom/pacman/quattro-repositories.conf`

**Interfaces:**
- Consumes: pinned Arch bootstrap tooling, pinned Bootcrew construction, pinned bootc source, and Omarchy stable repositories.
- Produces: a fatal-lint-clean stable foundation plus an OCI image containing `omarchy-settings 4.0.1-1`, `omarchy 4.0.1-1`, and the upstream base manifest closure.

- [ ] Extend the contract test with an ephemeral-root fixture proving package-list parsing ignores comments and blanks and rejects an unavailable base package.
- [ ] Run `just test-contract`; expect the new package-closure assertion to fail.
- [ ] Populate `/stable-root` from empty with the stable repository topology, materialize the package-owned sysusers/keyring/CA state, and prove no bootstrap package crosses into the root.
- [ ] Build pinned bootc inside the stable root, apply the pinned Bootcrew filesystem/initramfs construction, record both revisions in OCI labels, and prove `pacman -Qu` is empty.
- [ ] Install/populate `omarchy-keyring`, install exact Quattro packages and the upstream base manifest, and dependency-resolve the optional manifest without installing mutually exclusive hardware sets.
- [ ] Keep the publishable image free of a default user; in the acceptance image create the test identity only after disk installation and official `/etc/skel` availability, then invoke package-owned `omarchy-provision-user --first-install` on first boot.
- [ ] Run `just test-contract`; expect success.
- [ ] Run `just build localhost/omarchy-bootc quattro`; expect `bootc container lint` success.

### Task 3: Narrow boot ownership neutralization

**Files:**
- Create: `build/30-bootc-ownership.sh`
- Replace: `build/30-services.sh`
- Modify: `tests/test-quattro-source-contract.sh`

**Interfaces:**
- Consumes: the installed official Omarchy package graph.
- Produces: a dracut-generated bootc initramfs with conflicting Limine/Snapper units masked.

- [ ] Add a contract fixture that fails when `limine-snapper-sync.service`, `snapper-cleanup.timer`, or `snapper-timeline.timer` is active, or when the final initramfs lacks bootc/ostree modules.
- [ ] Run `just test-contract`; expect failure because the ownership script does not exist.
- [ ] Disable and mask only those three units, preserve package payloads, enable upstream SDDM and ordinary services, regenerate the latest-kernel initramfs with dracut, and inspect it with `lsinitrd` for bootc and ostree.
- [ ] Run `just test-contract && just validate && just lint`; expect success.
- [ ] Rebuild the OCI image and run `bootc container lint` inside it.

### Task 4: Quattro desktop VM acceptance

**Files:**
- Modify: `scripts/ci/vm-smoke.sh`
- Create: `scripts/ci/quattro-acceptance.sh`
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: bootc-installed Quattro image.
- Produces: artifact-backed proof of SDDM, `omarchy.desktop`, Hyprland, Quickshell, themes, menus, apps, and representative ordinary commands.

- [ ] Add a fixture mode to `quattro-acceptance.sh` that fails against the old minimal POC filesystem.
- [ ] Run the fixture; expect named missing Quattro artifacts.
- [ ] Implement in-VM assertions for SDDM enablement, `omarchy.desktop`, Hyprland, Quickshell, theme inventory, `omarchy-menu`, `omarchy-theme-list`, Ghostty, Chromium, and the upstream config seeded into the test user's home.
- [ ] Run the fixture; expect success against an extracted built image root.
- [ ] Run the KVM VM smoke path and retain serial/journal output.

### Task 5: bootc upgrade and rollback acceptance

**Files:**
- Create: `scripts/ci/bootc-lifecycle.sh`
- Modify: `.github/workflows/build.yml`
- Modify: `docs/technical-status.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: two locally tagged Quattro image revisions.
- Produces: VM evidence that bootc stages, boots, and rolls back deployments without invoking Omarchy's update pipeline.

- [ ] Create a fixture that rejects identical source and target image digests and records booted image identity before each transition.
- [ ] Run the fixture with identical tags; expect an explicit failure.
- [ ] Implement install, target-image switch/upgrade, reboot verification, rollback, and second reboot verification using a local registry and two OCI revisions.
- [ ] Run the lifecycle test under KVM and retain bootc status plus journal artifacts.
- [ ] Update documentation with verified results and keep `omarchy update` explicitly unproved.
- [ ] Run `just test-contract && just validate && just lint`, then the OCI build, Quattro VM acceptance, and lifecycle acceptance.

### Task 6: Additive upstream Omarchy ISO adapter

**Repository:** `dudley-iso`

**Files:**
- Create: a Quattro-specific backend adapter against pinned `omacom-io/omarchy-iso`
- Preserve: all existing Dudley, Dakota, and Bluefin installer variants and their tests
- Test: the pinned upstream `bin/omarchy-iso-test` and in-guest acceptance suite

**Interfaces:**
- Consumes: the signed Quattro OCI digest from this repository, the upstream configurator/orchestrator inputs, and upstream-created target mounts.
- Produces: an ISO with upstream Omarchy UX that replaces only pacstrap/Limine/mutable-root deployment with `bootc install to-filesystem`, deployment-specific `/etc` injection, and `bootc install finalize`.

- [ ] Build and retain a baseline ISO from upstream commit `268bac16d351a21d867e37565738f458b11cb06c`.
- [ ] Add a failing adapter contract proving the Quattro backend is variant-scoped and cannot alter existing installer image references, storage policy, provisioning, or branding.
- [ ] Implement only the deployment phase seam defined in `docs/installer-parity-contract.md`; preserve upstream configurator, dashboard, user finalizer, SDDM setup, autoinstall, and deferred provisioning.
- [ ] Run the same pinned upstream acceptance harness against baseline and Quattro ISOs for ordinary, encrypted, deferred-provisioning, and cidata paths.
- [ ] Prove the installed Quattro system references the expected signed OCI digest and passes bootc upgrade and rollback without exposing bootc terminology in the ordinary UX.
- [ ] Run every existing Dudley, Dakota, and Bluefin installer acceptance job unchanged; reject the change on any regression.
- [ ] Consider Dudley-specific branding only after the upstream-parity matrix passes.
