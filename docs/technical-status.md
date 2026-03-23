# Technical status: omarchy-bootc POC

_Last updated: 2026-03-23_

## Working now (implemented in repo)

- Build scripts are layered and wired from `Containerfile` with explicit boot-critical package lists in `custom/packages/base.packages`.
- Local build/qcow2/run flow is defined in `Justfile` with consistent local image reference defaults.
- A concrete VM login path is configured: `greetd` + `agreety` launching `Hyprland`, with minimal VM graphics/runtime packages (`mesa`, `vulkan-virtio`, `libinput`).
- A default POC user is explicitly created at image build time: `omarchy`.
- Root first-boot script seeds starter config and writes `/var/lib/omarchy/.firstboot-done`.
- Omarchy-style desktop defaults are imported in a constrained slice:
  - modular Hyprland config files (autostart, bindings, input, look/feel, monitors, window rules)
  - Waybar config/style defaults
  - Wofi launcher config/style defaults
  - Mako notification defaults
  - lock/screenshot UX bindings wired to shipped tools (`swaylock`, `grim`, `slurp`, `wl-clipboard`)

## Still unverified (needs real VM validation)

- bootc delivery/integration on Arch is currently not solved in this repository.
- End-to-end VM reliability across host environments.
- Desktop session quality/stability beyond first login.
- bootc lifecycle checks (rebase/rollback) on this Arch-based image (blocked until bootc delivery on Arch is solved here).
- Long-term assumptions around pacman DB relocation and bootc package behavior in Arch repos.

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
4. At agreety login with:
   - user: `omarchy`
   - password: `omarchy`
5. Confirm Hyprland session starts.
6. Verify first-boot completion in VM:
   - `test -f /var/lib/omarchy/.firstboot-done && echo OK`

Next milestone remains unchanged:

> Produce and validate a bootable qcow2 image in a VM.
