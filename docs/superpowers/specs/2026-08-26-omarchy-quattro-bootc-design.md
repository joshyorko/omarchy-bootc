# Omarchy Quattro on bootc Design

## Objective

Build an amd64 Arch bootc image that boots the official Omarchy Quattro v4.0.1 desktop without porting, recreating, or wrapping Omarchy.

## Architecture of record

Bootcrew mono is authoritative for Arch-on-bootc construction, filesystem semantics, dracut configuration, composefs preparation, and bootc linting. Its published rolling image is not a package source or final base.

Omarchy stable is authoritative for the final Arch package universe. A pinned current Arch container is used only as a disposable pacman tool. Pacman resolves the `base` group into an empty `/stable-root` against Omarchy's official stable core, extra, multilib, and omarchy repositories. No package from the disposable bootstrap image is copied into the final root and no bulk downgrade is used.

The pinned Bootcrew construction is then applied inside that stable root: bootc is compiled there against stable build dependencies, copied into a stable runtime root, and Bootcrew's pacman relocation, runtime dependency, dracut, `/usr`/`/var`, composefs, and tmpfiles construction is applied. Only after that foundation passes fatal bootc lint is the official Quattro closure installed.

## Immutable inputs

- Disposable Arch bootstrap: `docker.io/archlinux/archlinux:latest@sha256:0de35fe2ee793494ccfc99b202f6b30215b078baf2b082e9ccb027840c534fc1`.
- Bootcrew mono construction: commit `5f048fa65a94daefc814d3cdd941d8d1e113c09e`.
- bootc source: v1.16.10 commit `3e76c16556c55e6d15d31bd47602b231e2131cb2`.
- Omarchy release: v4.0.1 commit `13f18b2cb7286fb54f87daf571a031aa6af3d8f0`.
- Omarchy package repository implementation: `omacom-io/omarchy-pkgs` commit `f448847d1f6e664038636542502354a388cb0f94`.
- Official Omarchy ISO UX and acceptance reference: `omacom-io/omarchy-iso` Quattro commit `268bac16d351a21d867e37565738f458b11cb06c`.
- Repository topology: `omacom-io/omarchy-iso/configs/pacman-online-stable.conf` semantics for core, extra, multilib, and omarchy.
- Package manifests: `omarchy-base.packages` and `omarchy-other.packages` shipped by official `omarchy` 4.0.1-1.

The OCI image records both Bootcrew and bootc source revisions as labels. The executable contract rejects a rolling Bootcrew base, an unpinned bootc clone, or any `pacman -Syyuu` downgrade path.

## Quattro assembly and provenance

The official `omarchy-keyring`, `omarchy-settings=4.0.1-1`, and `omarchy=4.0.1-1` packages are installed unmodified. Every package in `omarchy-base.packages` is installed. The optional/hardware manifest is dependency-resolved package-by-package and recorded without installing mutually exclusive hardware sets.

Pacman ownership proves representative commands, Quickshell QML, themes, `/etc/skel` Hyprland configuration, SDDM theme, and canonical session file come from `omarchy` or `omarchy-settings`. The publishable image contains no default user, known password, or passwordless sudo rule.

## Boot ownership and explicit exceptions

Bootc exclusively owns deployment state, `/boot`, initramfs generation, image upgrades, and rollback. Official Limine, mkinitcpio, and Snapper packages remain installed because the official Omarchy package graph requires them.

Observed Limine/mkinitcpio pacman hooks are shadowed by valid, never-triggering hooks in a higher-priority bootc hook directory under the same five filenames. Three observed snapshot units are masked: `limine-snapper-sync.service`, `snapper-cleanup.timer`, and `snapper-timeline.timer`. `kernel-modules-hook` remains enabled and is recorded for lifecycle observation.

The pinned Bootcrew initramfs script explicitly adds `bootc`, while bootc v1.16.10's own base-image contract requires both `ostree` and `bootc`. The Quattro boot-ownership layer therefore adds a named final-layer dracut drop-in without modifying the vendored Bootcrew snapshot, then proves both modules, both root-setup services, and both setup binaries exist in the generated initramfs.

Bootcrew deliberately owns `/usr/local -> ../var/usrlocal`, while official packages place `omarchy.desktop` and a Limine mkinitcpio shim beneath `/usr/local`. The build temporarily materializes the directory for pacman, proves the official session file is byte-identical to its package-owned canonical source, projects it to `/usr/share/wayland-sessions/omarchy.desktop`, discards only the conflicting mkinitcpio shim, and restores Bootcrew's symlink. Pacman drift reporting names the resulting `/usr/local` hierarchy explicitly and rejects any unrelated drift.

## Acceptance identity and user finalization

Test credentials exist only in a non-publishable acceptance target. On the booted VM, acceptance automation creates the user after official `/etc/skel` is present and executes official `omarchy-provision-user --first-install` as that user. Acceptance proves the finalization marker, Tokyo Night generated state, skill symlinks, GTK bookmarks, migration markers, and idempotent second invocation.

## Acceptance order

1. Empty-root stable foundation builds with zero pending stable-repository changes and fatal bootc lint passes.
2. Official Quattro OCI image builds; package provenance and byte-identical projection pass; fatal bootc lint passes.
3. bootc installs the acceptance image to disk.
4. First boot runs official user finalization, reaches SDDM, and starts official `omarchy.desktop` Hyprland/Quickshell.
5. Themes, menus, representative apps, and ordinary non-update `omarchy-*` commands pass.
6. Two image revisions prove bootc upgrade, reboot identity, rollback, and second reboot identity.

## Installer and update boundaries

`dudley-iso` owns installer assembly and its existing product-specific variants. The Quattro path is additive: it must preserve the pinned official Omarchy ISO configurator, storage/encryption UX, questions, dashboard, user finalization, SDDM setup, and acceptance harness while replacing only the pacstrap/Limine/mutable-root deployment boundary with `bootc install to-filesystem`, target-deployment configuration, and `bootc install finalize`. It must not replace or regress the prescribed Dudley, Dakota, or Bluefin installer paths.

The normative UX, deployment seam, variant isolation, and same-harness acceptance requirements are in `docs/installer-parity-contract.md`. Branding is deferred until the upstream-looking Quattro flow passes that contract.

`omarchy update` integration remains read-only design work. The v4.0.1 investigation identifies `omarchy-update-system-pkgs` as the smallest upstream backend seam while preserving the public command, lock, migration, hook, notification, and restart UX. No update integration is implemented before desktop and bootc lifecycle acceptance.

## Non-goals

- No Bluefin, Dakota, Pneuma, Omedora, RPM, Flatpak, or Homebrew adaptation of Omarchy.
- No wrapper or replacement for an `omarchy-*` command.
- No rolling Bootcrew image inheritance or mixed package universe.
- No copied or recreated Omarchy installer UI and no shared-installer rewrite that changes existing Dudley variants.
- No claim that `omarchy update` works on the immutable deployment.
