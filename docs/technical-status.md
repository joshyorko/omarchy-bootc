# Technical status: Omarchy Quattro bootc

_Last updated: 2026-09-20_

## Architecture of record

The final image is an Omarchy-stable empty-root build. A digest-pinned current Arch container runs pacman against Omarchy's stable repositories and populates `/stable-root`; no package from the bootstrap container crosses into that root.
- Build scripts are layered and wired from `Containerfile` with explicit boot-critical package lists.
- bootc is built from the pinned v1.16.10 source revision and dracut is rebuilt with the bootc module.
- Sysroot is prepared for bootc/composefs with pacman state under `/usr/lib/sysimage`.
- Local build and qcow2/run flows are defined in `Justfile`; legacy bootc-image-builder fallbacks remain available.
- Installer ISO generation is Dagger-owned and remains an explicit/manual path.
- Rootful/rootless image handoff is explicit for the native disk-image and VM smoke paths.
- A concrete VM login path is configured with `greetd` + `agreety` launching Hyprland.

Bootcrew's published Arch image is not the final base and is not package authority. Bootcrew mono commit `5f048fa65a94daefc814d3cdd941d8d1e113c09e` is the source reference for pacman relocation, dracut, composefs, `/usr`/`/var`, tmpfiles, and bootc filesystem construction. Bootc is built from exact commit `3e76c16556c55e6d15d31bd47602b231e2131cb2`; an unpinned clone is forbidden.

## Implemented in the current branch

- Official stable repository topology for `core`, `extra`, `multilib`, and `omarchy`.
- Empty-root base package resolution; no inherited rolling Bootcrew package state and no bulk downgrade.
- Recorded Bootcrew and bootc source URLs, revisions, vendored checksums, OCI labels, and in-image revision files.
- Official `omarchy-keyring`, `omarchy-settings=4.0.4-1`, `omarchy=4.0.4-1`, and the current Quattro `omarchy-base.packages` closure at revision `45748a2812f42e32f915b053caf4074e150e2048`.
- Dependency-resolution report for `omarchy-other.packages` without installing mutually exclusive hardware stacks.
- Complete optional dependency resolution using the pinned official ISO's `arch-mact2` repository only in a temporary resolver config; the four-repository foundation remains unchanged.
- The current `arch-mact2` index omits `apple-bcm-firmware` still required by Omarchy. Resolve the checksum-pinned native `14.0-1` archive from that same configured mirror with `pacman -Up`, recording `resolvable-archive`, URL and checksum distinctly from indexed resolution. No extra repository is added, no hardware package is installed into the base, and the incompatible macOS-volume firmware fetcher is not substituted.
- Package provenance checks for commands, Quickshell, themes, `/etc/skel`, SDDM, and the canonical session file.
- One named `/usr/local` bootc projection exception for the package-owned session file, with byte-identity proof.
- Five observed Limine/mkinitcpio hooks shadowed and three observed snapshot units masked; `kernel-modules-hook` remains enabled and audited.
- Final dracut verification requires the bootc v1.16.10 `ostree` and `bootc` modules and both root-setup payloads; the correction is layered above the unmodified Bootcrew snapshot.
- Separate publishable and acceptance targets. The publishable image has no baked test account or passwordless sudo rule.
- Acceptance first boot invokes official `omarchy-provision-user --first-install`; local provisioning reimplementations remain forbidden.
- Cross-distro switching now uses structured strongest-to-weakest source evidence, persists the tracking ref and resolved digest, re-resolves immediately before `bootc switch`, and provides exact post-boot verification; the target adoption service retains independent mutable-state rollback.
- `omarchy update` and the update indicator now use the bootc-native `upgrade --check`/`upgrade` bridge; migrations are deferred to the first login after exact-digest verification.
- A scheduled/manual upstream Quattro tracker records drift as one advisory issue without repinning or publishing.

## Required publication evidence

- bootc lifecycle checks (upgrade/rebase/rollback) on this Arch-based image.
- End-to-end confirmation of the rootful-image handoff fix in GitHub Actions when `run_vm_smoke` is manually enabled.
- Reliability of `bootc install --composefs-backend --via-loopback` across host/container runtimes; qcow2 conversion relies on host `qemu-img`.
- End-to-end VM reliability across host environments.
- End-to-end validation of the existing ISO installer flow, especially the Bluefin live rootfs -> omarchy target handoff.
- Dagger Go SDK regeneration and full `just build-iso-local` execution on a host with Docker/Dagger engine access.
- Desktop session quality/stability beyond first login.
- Long-term assumptions around pacman DB relocation and bootc source build behavior over time.

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

The future Quattro path is a separate `dudley-iso` variant pinned to `omacom/omarchy-iso` Quattro commit `7cfb7111a06873d61c45d37034577d4ba08d3f4f`. Its contract is upstream Omarchy UX plus a narrow `bootc install to-filesystem` backend; Gate 6 remains out of scope for this repository.


See `docs/installer-parity-contract.md` for the normative installer and non-regression requirements.

## Deferred

- Hosted Podman/KVM assembled-image, plugin/OMP, A/B rollback, and Dakota round-trip evidence remain runtime gates; they are blocked when the required image registry, VM, or hypervisor capability is unavailable, never inferred from shell contracts.
- Gate 6 installer execution remains in `dudley-iso` and is not claimed by this repository.
- No installer UI fork or local reimplementation of Omarchy user provisioning.
- No arbitrary-source switch is accepted; Bluefin, Dakota, and existing Omarchy transitions still require clean VM evidence for adoption, independent recovery, and reverse rollback.
- No publication, ISO replacement, or claim of desktop/lifecycle completion before the gates above pass.
