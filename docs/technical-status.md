# Technical status: omarchy-bootc POC

_Last updated: 2026-04-19_

## Working now (implemented in repo)

- Build scripts are layered and wired from `Containerfile` with explicit boot-critical package lists in `custom/packages/base.packages` (including `dracut` for bootc initramfs rebuilds and BIB fallback if needed).
- bootc is built from source during image build (default `BOOTC_REF=v1.13.0`), dracut is rebuilt with the `bootc` module, and bootc container metadata/lint are applied.
- Sysroot is prepared for bootc/composefs (`HOME=/var/home`, `/usr/lib/sysimage` pacman paths, tmpfiles for mutable dirs, `prepare-root.conf` enabling composefs/readonly sysroot).
- Local build/qcow2/run flow is defined in `Justfile` with consistent local image reference defaults.
- Native `bootc install to-disk` path emits raw/qcow2 images via `just build-qcow2`; legacy bootc-image-builder targets remain available as `build-qcow2-bib` / `build-raw-bib`.
- Rootful/rootless image handoff is now explicit for the native disk-image path: `Justfile` and `scripts/ci/vm-smoke.sh` copy the already-built image into rootful podman before running `bootc install to-disk`.
- CI installs `systemd-container` so `machinectl` is available for the `podman image scp` handoff used by the smoke path.
- A concrete VM login path is configured: `greetd` + `agreety` launching `Hyprland`, with minimal VM graphics/runtime packages (`mesa`, `vulkan-virtio`, `libinput`).
- A default POC user is explicitly created at image build time: `omarchy`.
- Root first-boot script seeds starter config and writes `/var/lib/omarchy/.firstboot-done`.
- Omarchy-style desktop defaults are imported in a constrained slice:
  - modular Hyprland config files (autostart, bindings, input, look/feel, monitors, window rules)
  - Waybar config/style defaults
  - Wofi launcher config/style defaults
  - Mako notification defaults
  - lock/screenshot UX bindings wired to shipped tools (`swaylock`, `grim`, `slurp`, `wl-clipboard`)

## Most recent blocker addressed in repo

- The old PR `#14` failure mode (`image ... is not a bootc image`) was superseded by merged PR `#15`, which added bootc source builds plus `bootc container lint`.
- The repeated `main` workflow failure after PR `#15` was a different issue: CI copied the image into rootful podman with `podman image save` / `load`, then `bootc install to-disk` failed reopening the image from `containers-storage` with missing config-blob errors.
- The repo now uses a storage-native rootful copy step (`podman image scp`) for both local native disk-image builds and CI smoke tests.

## Still unverified (needs broader VM validation)

- bootc lifecycle checks (upgrade/rebase/rollback) on this Arch-based image.
- End-to-end confirmation of the rootful-image handoff fix in GitHub Actions after a fresh workflow rerun.
- Reliability of `bootc install --composefs-backend --via-loopback` across host/container runtimes; qcow2 conversion relies on host `qemu-img`.
- End-to-end VM reliability across host environments.
- Desktop session quality/stability beyond first login.
- Long-term assumptions around pacman DB relocation and bootc source build behavior over time.

## Deferred intentionally

- Full Omarchy package/config parity (Omarchy helper command ecosystem, theme engine, app presets).
- AUR-heavy theming stack in base image.
- BuildStream.
- Installer media.

## Explicitly deferred from imported Omarchy behavior

- Omarchy-specific wrapper commands (`omarchy-*`) referenced in upstream configs are not imported in this slice.
- Walker-based launcher workflow is deferred; this image continues using `wofi` defaults.
- Theme/template expansion pipeline (`~/.config/omarchy/current/theme/*`) is deferred.
- User-level setup tooling beyond first-boot config seeding remains deferred.

## Manual smoke test (target path)

1. `just build`
2. `just build-qcow2`
3. `just run-vm`
4. At the agreety prompt login with:
   - user: `omarchy`
   - password: `omarchy`
5. Confirm Hyprland session starts.
6. Verify first-boot completion in VM:
   - `test -f /var/lib/omarchy/.firstboot-done && echo OK`

Next milestone remains unchanged:

> Keep qcow2 generation + headless VM smoke checks green in CI, then expand diagnostics and stability coverage.
