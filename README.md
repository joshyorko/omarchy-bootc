# omarchy-bootc

An **Arch Linux**-based [bootc](https://github.com/bootc-dev/bootc) technical proof-of-concept for an
Omarchy-aligned immutable desktop image.

## Current POC scope

Implemented in this repository:

- OCI build on `archlinux:base` using layered scripts in `build/`.
- qcow2 generation path via `bootc-image-builder`.
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
- Installer media.
- BuildStream flow.
- AUR-heavy theming stack and Omarchy helper-script ecosystem.

## Repository layout

```text
omarchy-bootc/
├── build/                              # image build-time scripts
├── custom/packages/                    # package lists
├── custom/greetd/config.toml           # greetd/agreety login command
├── custom/first-boot/omarchy-setup.sh  # root first-boot logic
├── custom/hypr/                         # staged Hyprland defaults
├── custom/skel/                         # starter home config skeleton
├── systemd/system/omarchy-firstboot.service
├── image/disk.toml                     # bootc-image-builder config
├── Justfile
└── docs/technical-status.md
```

## Prerequisites

- `podman`
- `just`
- `jq`
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

The image now includes explicit boot-critical packages (`linux`, `dracut`, `kmod`, `btrfs-progs`) and a minimal VM graphics stack (`mesa`, `vulkan-virtio`, `libinput`).

Remaining assumptions to validate in real VM boots:

- `bootc` delivery/integration on Arch is not solved in this repo yet (package is not currently available in CI repos).
- `bootc-image-builder` relies on `lsinitrd` during manifest/qcow2 generation; this image now provides it via `dracut`.
- `bootc-image-builder` reliably produces a bootable Arch qcow2 from this image layout.
- Arch `bootc` package behavior remains compatible with this flow over time.
- Hyprland compositor behavior in a virtualized GPU environment is host/hypervisor dependent.

See `docs/bootc-delivery-options.md` for current Arch bootc delivery options and the recommended path forward.
See `docs/bootcrew-comparison.md` for how bootcrew’s Arch bootc images differ and the minimal next step to align.

## Notes

- This remains a technical POC for an Omarchy-style Arch image.
- bootc delivery/integration on Arch is currently deferred until a real package/source path is validated.
- Immediate objective is to keep the image building while preserving the first VM login/session path.
- Desktop defaults are now intentionally Omarchy-inspired but trimmed to the current package set and no-AUR policy.
- See `docs/technical-status.md` for what is working, what is assumed, and what is deferred.
- Current CI focus: keep image build + headless VM smoke validation green.
- Next milestone remains: harden the smoke path with richer failure artifacts/log collection.
