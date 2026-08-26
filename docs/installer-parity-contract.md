# Omarchy Quattro installer parity contract

## Status and ownership

This is the normative contract for a future Omarchy Quattro installer variant in `dudley-iso`. It does not implement that adapter in this image repository.

The Quattro path is an additive installer variant. It must not replace, mutate, or regress any existing Dudley, Dakota, or Bluefin installer variant. Each product keeps its prescribed installer, tests, image reference, storage policy, and release path.

## Pinned upstream reference

- Source: `https://github.com/omacom-io/omarchy-iso.git`
- Branch reviewed: `quattro`
- Revision: `268bac16d351a21d867e37565738f458b11cb06c`
- Archiso submodule at that revision: `424e78130db2af6c1ceb55b442d7914b1109ff2b`
- Target OCI: the signed Omarchy Quattro bootc image produced by this repository from the Omarchy-stable package universe

The pinned upstream revision owns the configurator, storage and encryption questions, user questions, install dashboard, phase sequencing, autoinstall inputs, official user finalization, SDDM/login setup, and QEMU/OCR acceptance harness. The Quattro variant should track upstream by rebasing a narrow backend adapter, not by copying or visually recreating those surfaces.

## User-facing acceptance requirement

Except for deliberately branded copy approved after parity and bootc-specific diagnostic surfaces a user intentionally opens, the interactive installer, questions, first-install provisioning, SDDM/login behavior, Quattro session, user defaults, applications, themes, menus, shell, keybindings, and ordinary Omarchy commands must be behaviorally equivalent to the pinned official Omarchy Quattro ISO.

The ordinary install flow must remain:

```text
official Omarchy configurator
  -> official disk and encryption questions
  -> official username and password questions
  -> official install dashboard and progress
  -> reboot
  -> official Omarchy SDDM
  -> official Quattro Hyprland and Quickshell session
```

Bootc, OSTree, composefs, OCI, dracut, deployment, and rollback terminology must not appear in the ordinary installer UX.

## Only permitted implementation seam

The implementation may diverge only at the OS deployment and boot-ownership boundary. Preserve upstream partitioning, formatting, encryption, mounting, configurator state, dashboard state, and machine/user inputs. Replace pacstrap/package installation, Limine installation or finalization, mutable-root construction, and Snapper factory-root assumptions with a tested deployment of the signed OCI.

The adapter must invoke bootc from the target OCI context and use the external-installer path:

```bash
bootc install to-filesystem /mnt
```

After deployment, locate the current target deployment before writing machine-specific `/etc` state:

```bash
ostree admin --sysroot=/mnt --print-current-dir
```

Machine-specific configuration is limited to values collected or authorized by the official installer, including hostname, timezone, account and password state, storage/encryption metadata, SDDM/login state, authorized keys, and optional Tailscale provisioning. Before unmounting, the adapter must run:

```bash
bootc install finalize /mnt
```

Bootc exclusively owns the installed boot filesystem, initramfs, deployment state, OS upgrade, and rollback. The adapter must not run Limine, mkinitcpio, Snapper factory-root, or package-update operations against those surfaces.

## Official provisioning is retained

The installed OCI supplies official `omarchy-settings` `/etc/skel` and official `omarchy` commands. The upstream installer creates the selected account only after that deployment exists, then runs the package-owned finalizer as the selected user:

```bash
omarchy-provision-user --first-install
```

Deferred provisioning remains the upstream deferred path. The adapter must not add local user-creation, skeleton-seeding, first-boot, theme, browser, keyring, migration, or application wrappers.

## Acceptance and non-regression gates

Build the pinned official ISO as a baseline and the Quattro bootc ISO from the same pinned source plus the backend adapter. Run both through the same pinned upstream acceptance harness. At minimum, compare:

- ordinary interactive installation;
- encrypted interactive installation;
- deferred owner provisioning;
- cidata autoinstall;
- configurator and dashboard checkpoints;
- reboot, SDDM login, and official Quattro session;
- the upstream in-guest acceptance suite for desktop, user defaults, packages, apps, menus, panels, shell behavior, and ordinary commands.

The Quattro result must retain the upstream screenshot, serial, installer-log, and in-guest test artifacts. It must additionally prove the installed deployment references the expected signed OCI digest and that `bootc status`, upgrade, reboot, rollback, and second reboot work without changing the upstream-facing UX.

Existing Dudley, Dakota, and Bluefin installer jobs continue to run their own prescribed acceptance suites. A Quattro adapter change cannot make those variants inherit Omarchy storage, provisioning, branding, or image-selection behavior.

## Branding and non-goals

Branding is deferred until the pinned official installer plus bootc deployment seam passes the parity matrix. The first accepted implementation should look like upstream Omarchy apart from diagnostics intentionally inspected by a tester.

This contract does not authorize a forked installer UI, a Dudley reimplementation of Omarchy provisioning, a wrapper around an `omarchy-*` command, or changes to the existing installer variants.
