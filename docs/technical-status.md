# Technical status: Omarchy Quattro bootc

_Last updated: 2026-08-26_

## Architecture of record

The final image is an Omarchy-stable empty-root build. A digest-pinned current Arch container runs pacman against Omarchy's stable repositories and populates `/stable-root`; no package from the bootstrap container crosses into that root.

Bootcrew's published Arch image is not the final base and is not package authority. Bootcrew mono commit `5f048fa65a94daefc814d3cdd941d8d1e113c09e` is the source reference for pacman relocation, dracut, composefs, `/usr`/`/var`, tmpfiles, and bootc filesystem construction. Bootc is built from exact commit `3e76c16556c55e6d15d31bd47602b231e2131cb2`; an unpinned clone is forbidden.

## Implemented in the current branch

- Official stable repository topology for `core`, `extra`, `multilib`, and `omarchy`.
- Empty-root base package resolution; no inherited rolling Bootcrew package state and no bulk downgrade.
- Recorded Bootcrew and bootc source URLs, revisions, vendored checksums, OCI labels, and in-image revision files.
- Official `omarchy-keyring`, `omarchy-settings=4.0.1-1`, `omarchy=4.0.1-1`, and upstream `omarchy-base.packages` closure.
- Dependency-resolution report for `omarchy-other.packages` without installing mutually exclusive hardware stacks.
- Package provenance checks for commands, Quickshell, themes, `/etc/skel`, SDDM, and the canonical session file.
- One named `/usr/local` bootc projection exception for the package-owned session file, with byte-identity proof.
- Five observed Limine/mkinitcpio hooks shadowed and three observed snapshot units masked; `kernel-modules-hook` remains enabled and audited.
- Separate publishable and acceptance targets. The publishable image has no baked test account or passwordless sudo rule.
- Acceptance first boot invokes official `omarchy-provision-user --first-install`; local provisioning reimplementations remain forbidden.

## Required publication evidence

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
- No publication, ISO replacement, or claim of desktop/lifecycle completion before the gates above pass.
