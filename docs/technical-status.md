# Technical status: Omarchy Quattro bootc

_Last updated: 2026-08-26_

## Architecture of record

<<<<<<< HEAD
The final image is an Omarchy-stable empty-root build. A digest-pinned current Arch container runs pacman against Omarchy's stable repositories and populates `/stable-root`; no package from the bootstrap container crosses into that root.
=======
- Build scripts are layered and wired from `Containerfile` with explicit boot-critical package lists in `custom/packages/base.packages` (including `dracut` for bootc initramfs rebuilds and BIB fallback if needed).
- bootc is built from source during image build (default `BOOTC_REF=v1.13.0`), dracut is rebuilt with the `bootc` module, and bootc container metadata/lint are applied.
- Sysroot is prepared for bootc/composefs (`HOME=/var/home`, `/usr/lib/sysimage` pacman paths, tmpfiles for mutable dirs, `prepare-root.conf` enabling composefs/readonly sysroot).
- Local build/qcow2/run flow is defined in `Justfile` with consistent local image reference defaults.
- Native `bootc install to-disk` path emits raw/qcow2 images via `just build-qcow2`; legacy bootc-image-builder targets remain available as `build-qcow2-bib` / `build-raw-bib`.
- Manual/opt-in installer ISO workflows now exist in GitHub Actions: `build-iso.yml` can build an ISO from a published tag, and `build.yml` has a manual `build_iso` toggle.
- The expensive qcow2 + headless QEMU smoke path is manual-only in `build.yml` behind the `run_vm_smoke` dispatch toggle.
- Installer ISO generation is Dagger-owned: `just build-iso-local` and the reusable GitHub workflow both call the same Dagger `build-iso` function and export artifacts under `output/iso`.
- The initial installer path uses a Fedora-based Bluefin live rootfs with Titanoboa, but installs the published `ghcr.io/joshyorko/omarchy-bootc:<tag>` container onto the target system.
- The Dagger module source is present under `.dagger/`; Go SDK support files are regenerated with `just dagger-develop` on a host that can start the Dagger engine.
- Rootful/rootless image handoff is now explicit for the native disk-image path: `Justfile` and `scripts/ci/vm-smoke.sh` copy the already-built image into rootful podman, export an OCI install source, and pass `--source-imgref` to `bootc install to-disk`.
- Manual VM smoke runs install `systemd-container` so `machinectl` is available for the `podman image scp` handoff used by the smoke path.
- A concrete VM login path is configured: `greetd` + `agreety` launching `Hyprland`, with minimal VM graphics/runtime packages (`mesa`, `vulkan-virtio`, `libinput`).
- A default POC user is explicitly created at image build time: `omarchy`.
- Root first-boot script seeds starter config and writes `/var/lib/omarchy/.firstboot-done`.
- Omarchy-style desktop defaults are imported in a constrained slice:
  - modular Hyprland config files (autostart, bindings, input, look/feel, monitors, window rules)
  - Waybar config/style defaults
  - Wofi launcher config/style defaults
  - Mako notification defaults
  - lock/screenshot UX bindings wired to shipped tools (`swaylock`, `grim`, `slurp`, `wl-clipboard`)
>>>>>>> origin/main

Bootcrew's published Arch image is not the final base and is not package authority. Bootcrew mono commit `5f048fa65a94daefc814d3cdd941d8d1e113c09e` is the source reference for pacman relocation, dracut, composefs, `/usr`/`/var`, tmpfiles, and bootc filesystem construction. Bootc is built from exact commit `3e76c16556c55e6d15d31bd47602b231e2131cb2`; an unpinned clone is forbidden.

## Implemented in the current branch

- Official stable repository topology for `core`, `extra`, `multilib`, and `omarchy`.
- Empty-root base package resolution; no inherited rolling Bootcrew package state and no bulk downgrade.
- Recorded Bootcrew and bootc source URLs, revisions, vendored checksums, OCI labels, and in-image revision files.
- Official `omarchy-keyring`, `omarchy-settings=4.0.1-1`, `omarchy=4.0.1-1`, and upstream `omarchy-base.packages` closure.
- Dependency-resolution report for `omarchy-other.packages` without installing mutually exclusive hardware stacks.
- Complete optional dependency resolution using the pinned official ISO's `arch-mact2` repository only in a temporary resolver config; the four-repository foundation remains unchanged.
- Package provenance checks for commands, Quickshell, themes, `/etc/skel`, SDDM, and the canonical session file.
- One named `/usr/local` bootc projection exception for the package-owned session file, with byte-identity proof.
- Five observed Limine/mkinitcpio hooks shadowed and three observed snapshot units masked; `kernel-modules-hook` remains enabled and audited.
- Final dracut verification requires the bootc v1.16.10 `ostree` and `bootc` modules and both root-setup payloads; the correction is layered above the unmodified Bootcrew snapshot.
- Separate publishable and acceptance targets. The publishable image has no baked test account or passwordless sudo rule.
- Acceptance first boot invokes official `omarchy-provision-user --first-install`; local provisioning reimplementations remain forbidden.
- Cross-distro switching now has an explicit source-aware preflight/capture/backup helper and a target adoption service with independent mutable-state rollback; fresh ISO installs bypass it through an installer-origin marker.

<<<<<<< HEAD
## Required publication evidence
=======
- bootc lifecycle checks (upgrade/rebase/rollback) on this Arch-based image.
- End-to-end confirmation of the rootful-image handoff fix in GitHub Actions when `run_vm_smoke` is manually enabled.
- Reliability of `bootc install --composefs-backend --via-loopback` across host/container runtimes; qcow2 conversion relies on host `qemu-img`.
- End-to-end VM reliability across host environments.
- End-to-end validation of the new ISO installer flow, especially the Bluefin live rootfs -> omarchy target handoff.
- Dagger Go SDK regeneration and full `just build-iso-local` execution on a host with Docker/Dagger engine access.
- Desktop session quality/stability beyond first login.
- Long-term assumptions around pacman DB relocation and bootc source build behavior over time.
>>>>>>> origin/main

The following are gates, not inferred results:

1. Build the pinned empty-root foundation and prove `pacman -Qu` is empty.
2. Inspect exact Bootcrew and bootc revision labels and in-image source records.
3. Pass fatal `bootc container lint` on foundation, Quattro, acceptance, and final targets.
4. Install the acceptance OCI to disk and prove the first-boot finalizer marker and representative runtime-only setup.
5. Reach official SDDM and official `omarchy.desktop` Hyprland/Quickshell.
6. Exercise themes, menus, representative apps, shell behavior, and ordinary package-owned `omarchy-*` commands.
7. Boot a second OCI revision, verify the upgrade, roll back, reboot, and verify the original deployment.

Focused shell and source-contract checks do not substitute for assembled-image, VM, or lifecycle evidence.

## Installer status

The existing installer workflows are preserved. They are not silently converted into a shared Omarchy installer.

The future Quattro path is a separate `dudley-iso` variant pinned to `omacom-io/omarchy-iso` Quattro commit `268bac16d351a21d867e37565738f458b11cb06c`. Its contract is upstream Omarchy UX plus a narrow `bootc install to-filesystem` backend seam. The same pinned upstream QEMU/OCR and in-guest acceptance harness must pass for the official baseline and the Quattro bootc ISO. Branding waits until that parity proof succeeds.

See `docs/installer-parity-contract.md` for the normative installer and non-regression requirements.

## Deferred

- No implementation of `omarchy update` integration yet.
- No wrapper or replacement for any `omarchy-*` command.
- No installer UI fork or local reimplementation of Omarchy user provisioning.
- No arbitrary-source switch is accepted; Bluefin, Dakota, and existing Omarchy transitions still require clean VM evidence for adoption, independent recovery, and reverse rollback.
- No publication, ISO replacement, or claim of desktop/lifecycle completion before the gates above pass.
