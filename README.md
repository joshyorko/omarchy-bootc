# omarchy-bootc

An **Arch Linux**-based [bootc](https://github.com/bootc-dev/bootc) technical proof-of-concept for an
Omarchy-aligned immutable desktop image.

## Current POC scope

Implemented in this repository:

- OCI build on `archlinux:base` using layered scripts in `build/`.
- qcow2 generation path via `bootc-image-builder`.
- Explicit VM login path: `greetd + tuigreet + Hyprland`.
- Explicit default POC user: `omarchy` / `omarchy` (documented insecure default for local VM testing).
- One-shot root first-boot setup that seeds starter config and marks completion.

Still intentionally out of scope:

- Full Omarchy parity.
- Installer media.
- BuildStream flow.

## Repository layout

```text
omarchy-bootc/
├── build/                              # image build-time scripts
├── custom/packages/                    # package lists
├── custom/greetd/config.toml           # greetd/tuigreet login command
├── custom/first-boot/omarchy-setup.sh  # root first-boot logic
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

1. At `tuigreet`, log in as:
   - user: `omarchy`
   - password: `omarchy`
2. Session command is preconfigured to start `Hyprland`.
3. Verify first boot completed:
   ```bash
   test -f /var/lib/omarchy/.firstboot-done && echo OK
   ```

> ⚠️ The default `omarchy/omarchy` credential is for first local VM bring-up only.
> Change it immediately in any persistent environment.

## Boot assumptions / known blockers

The image now includes explicit boot-critical packages (`linux`, `mkinitcpio`, `kmod`, `btrfs-progs`) and a minimal VM graphics stack (`mesa`, `vulkan-virtio`, `libinput`).

Remaining assumptions to validate in real VM boots:

- `bootc-image-builder` reliably produces a bootable Arch qcow2 from this image layout.
- Arch `bootc` package behavior remains compatible with this flow over time.
- Hyprland compositor behavior in a virtualized GPU environment is host/hypervisor dependent.

## Notes

- This remains a technical POC.
- See `docs/technical-status.md` for what is working, what is assumed, and what is deferred.
- Next milestone remains: **produce and validate a bootable qcow2 image in a VM**.
