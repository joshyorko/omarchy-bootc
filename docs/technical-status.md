# Technical status: omarchy-bootc POC

_Last updated: 2026-03-22_

## Working now (implemented in repo)

- Build scripts are layered and wired from `Containerfile` with explicit boot-critical package lists in `custom/packages/base.packages`.
- Local build/qcow2/run flow is defined in `Justfile` with consistent local image reference defaults.
- A concrete VM login path is configured: `greetd` + `tuigreet` launching `Hyprland`, with minimal VM graphics/runtime packages (`mesa`, `vulkan-virtio`, `libinput`).
- A default POC user is explicitly created at image build time: `omarchy`.
- Root first-boot script seeds starter config and writes `/var/lib/omarchy/.firstboot-done`.

## Still unverified (needs real VM validation)

- End-to-end VM reliability across host environments.
- Desktop session quality/stability beyond first login.
- bootc lifecycle checks (rebase/rollback) on this Arch-based image.
- Long-term assumptions around pacman DB relocation and bootc package behavior in Arch repos.

## Deferred intentionally

- Full Omarchy package/config parity.
- AUR-heavy theming stack in base image.
- BuildStream.
- Installer media.

## Manual smoke test (target path)

1. `just build`
2. `just build-qcow2`
3. `just run-vm`
4. At tuigreet login with:
   - user: `omarchy`
   - password: `omarchy`
5. Confirm Hyprland session starts.
6. Verify first-boot completion in VM:
   - `test -f /var/lib/omarchy/.firstboot-done && echo OK`

Next milestone remains unchanged:

> Produce and validate a bootable qcow2 image in a VM.
