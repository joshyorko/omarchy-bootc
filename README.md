# omarchy-bootc

An **Arch Linux**-based [bootc](https://github.com/bootc-dev/bootc) technical proof-of-concept for an
Omarchy-aligned immutable desktop image.

## Current POC scope

Implemented in this repository:

- OCI build on `archlinux:base` using layered scripts in `build/`.
- qcow2 generation path via native `bootc install to-disk`, with `bootc-image-builder` kept as the fallback path.
- Omarchy-style Arch VM session path (`greetd` + `agreety` + `Hyprland`) remains the active focus.
- Explicit VM login path: `greetd + agreety + Hyprland`.
- Explicit default POC user: `omarchy` / `omarchy` (documented insecure default for local VM testing).
- One-shot root first-boot setup that seeds starter user config and marks completion.
- Imported Omarchy-inspired desktop defaults for:
  - Hyprland modular config (`~/.config/hypr/*`)
  - Waybar defaults
  - Wofi launcher defaults
  - Mako notification defaults
  - Lock/screenshot keybindings (`swaylock`, `grim`, `slurp`, `wl-clipboard`)

Still intentionally out of scope:

- Full Omarchy parity.
- BuildStream flow.
- AUR-heavy theming stack and Omarchy helper-script ecosystem.

## Repository layout

```text
omarchy-bootc/
├── build/                              # image build-time scripts
├── custom/packages/                    # package lists
├── custom/greetd/config.toml           # greetd/agreety login command
├── custom/first-boot/omarchy-setup.sh  # root first-boot logic
├── custom/hypr/                        # staged Hyprland defaults
├── iso_files/                          # installer hook templates/scripts
├── systemd/system/omarchy-firstboot.service
├── image/disk.toml                     # bootc-image-builder config
├── Justfile
└── docs/technical-status.md
```

## Prerequisites

- `podman`
- `just`
- `jq`
- `machinectl` (required when the native disk-image recipes need to copy a rootless-built image into rootful podman)
- `sudo` (for rootful bootc-image-builder)
- `/dev/kvm` for practical VM boot testing

Run `just validate` before build.

## Local build + VM smoke test

```bash
# 1) Build local OCI image (tag/ref used by all recipes)
just build

# 2) Convert to qcow2
just build-qcow2

# 3) Boot VM
just run-vm
```

> Default qcow2 generation uses `bootc install --composefs-backend --via-loopback` and requires host `qemu-img` plus `--privileged` podman. Use `just build-qcow2-bib` if you need the legacy bootc-image-builder path.
> The native disk-image recipes copy the locally-built image into rootful podman and export an OCI directory source before `bootc install to-disk`, which avoids the rootful `containers-storage:` reopen failure when the build itself ran rootless.

## CI installer ISO workflow

Installer media now follows the Dudley-style flow shape: build and publish the container image first, then build the ISO from the published tag only when you ask for it.

- `build-iso.yml` is manual-only and defaults to `stable`
- `build.yml` exposes a `build_iso` toggle on manual dispatch; it defaults to `false`
- `build.yml` also exposes a manual-only `run_vm_smoke` toggle for the expensive qcow2 + headless QEMU smoke path
- the ISO workflow uses `ublue-os/titanoboa`, but the live installer rootfs is a Fedora-based Bluefin image while the installed target is `ghcr.io/joshyorko/omarchy-bootc:<tag>`

That split matters here because Titanoboa’s live rootfs still expects Fedora tooling, while the installed system remains the Arch-based omarchy bootc image.

For local installer testing, keep the disk-image and installer flows separate:

```bash
# Build the installer ISO by running the GitHub Actions ISO workflow locally.
just build-iso-local

# Boot the newest output/*.iso through the same browser VM UI as just run-vm.
just run-installer-iso
```

`just run-vm` boots an already-installed qcow2 image. `just run-installer-iso` boots installer media and should land in the Anaconda-based installer session.
By default the ISO installs `ghcr.io/joshyorko/omarchy-bootc:stable`; pass a full image ref to test another registry/tag:

```bash
just build-iso-local stable ghcr.io/joshyorko/omarchy-bootc:some-test-tag
```

### Login/session path in VM

1. At the `agreety` prompt, log in as:
   - user: `omarchy`
   - password: `omarchy`
2. Session command is preconfigured to start `Hyprland`.
3. Verify first boot completed:
   ```bash
   test -f /var/lib/omarchy/.firstboot-done && echo OK
   ```
4. Verify starter config seeded:
   ```bash
   ls ~/.config/hypr ~/.config/waybar ~/.config/wofi ~/.config/mako
   ```

> ⚠️ The default `omarchy/omarchy` credential is for first local VM bring-up only.
> Change it immediately in any persistent environment.

## Boot assumptions / known blockers

The image now includes explicit boot-critical packages (`linux`, `dracut`, `kmod`, `btrfs-progs`) and a minimal VM graphics stack (`mesa`, `vulkan-virtio`, `libinput`). `bootc` is built from source during the image build with dracut drop-ins, and the sysroot is prepared for composefs/ostree (`HOME=/var/home`).

Remaining assumptions to validate in real VM boots:

- `bootc install to-disk` (used by `just build-qcow2` / CI smoke) remains reliable across host environments once the rootful image handoff is in place; qcow2 conversion requires `qemu-img`.
- `bootc` lifecycle operations (upgrade/rebase/rollback) on this Arch-based image still need broader validation.
- `bootc-image-builder` remains available as a fallback path via `just build-qcow2-bib`.
- Hyprland compositor behavior in a virtualized GPU environment is host/hypervisor dependent.

See `docs/bootc-delivery-options.md` for current Arch bootc delivery options and the recommended path forward (now implemented via source build).
See `docs/bootcrew-comparison.md` for how bootcrew’s Arch bootc images differ and what remains to align.

## Notes

- This remains a technical POC for an Omarchy-style Arch image.
- bootc is shipped from source inside the image; keep validating the bootc/composefs flow over time.
- Immediate objective is to keep the image building while preserving the first VM login/session path and the bootc install-to-disk smoke path.
- Desktop defaults are now intentionally Omarchy-inspired but trimmed to the current package set and no-AUR policy.
- See `docs/technical-status.md` for what is working, what is assumed, and what is deferred.
- Current CI focus: keep image builds green by default while preserving VM smoke validation as an explicit manual dispatch option.
- Next milestone remains: validate the first installer ISO end to end, then decide whether the manual VM smoke path is still worth maintaining.
