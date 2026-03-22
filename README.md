# omarchy-bootc

An **Arch Linux**-based [bootc](https://github.com/bootc-dev/bootc) technical proof-of-concept for an
Omarchy-aligned immutable desktop image.

Repository structure is inspired by [projectbluefin/finpilot](https://github.com/projectbluefin/finpilot),
but this project remains **Arch + pacman** focused.

---

## Current status (honest summary)

What is currently implemented:

- OCI image build on `archlinux:base` with layered build scripts (`build/*.sh`).
- Bootc-focused image layout assumptions (including pacman DB relocation into `/usr/lib/sysimage/pacman`).
- A minimal Hyprland/Wayland package baseline in `custom/packages/omarchy.packages`.
- A first-boot root service that seeds starter user config when a regular user exists.
- Local workflow recipes (`just`) for image build, qcow2 conversion via bootc-image-builder, and VM run.

What is **not** yet proven here:

- End-to-end validated boot/rebase lifecycle in real VMs across upgrades.
- Full Omarchy package/config parity.
- Installer media.
- BuildStream-based flow.

See `docs/technical-status.md` for a precise breakdown of working vs unverified areas.

---

## Repository layout

```text
omarchy-bootc/
├── .github/workflows/build.yml         # Build + publish container image
├── build/
│   ├── 10-base.sh                      # Base package + staged assets
│   ├── 20-omarchy.sh                   # Minimal Omarchy/Hyprland baseline
│   ├── 30-services.sh                  # Service enablement
│   └── README.md
├── custom/
│   ├── first-boot/omarchy-setup.sh     # Root first-boot setup
│   ├── hypr/hyprland.conf.example      # Starter Hyprland config
│   └── packages/
│       ├── base.packages
│       └── omarchy.packages
├── docs/technical-status.md            # Working/assumed/deferred matrix
├── image/disk.toml                     # bootc-image-builder config
├── systemd/system/omarchy-firstboot.service
├── Containerfile
├── Justfile
└── README.md
```

---

## Prerequisites

- `podman`
- `just`
- `jq`
- `sudo` (for rootful bootc-image-builder usage)
- VM runtime support (`/dev/kvm` strongly recommended)

Optional but useful:

- `shellcheck`, `shfmt`, `ss` (iproute2)

Run `just validate` before builds to check expected tools/files.

---

## Local workflow

```bash
# inspect recipe groups and notes
just help

# verify host + repo preconditions
just validate

# build OCI image
just build

# convert OCI image to qcow2 via bootc-image-builder (requires sudo/rootful podman)
just build-qcow2

# run VM using qemux wrapper (requires /dev/kvm)
just run-vm
```

Expected qcow2 output path:

```text
output/qcow2/disk.qcow2
```

---

## CI workflow summary

`.github/workflows/build.yml` currently:

- builds on PRs and pushes to `main`
- pushes images to GHCR only on default-branch pushes
- includes optional (commented) sections for cosign signing + SBOM attestations

It intentionally avoids claiming release-grade provenance until signing/SBOM policy is enabled.

---

## Scope boundaries

This repository is intentionally conservative in v1 scope:

- **in scope now:** bootable-image POC work, qcow2 conversion path, minimal desktop baseline
- **deferred:** BuildStream, installer media, full Omarchy reproduction

Next milestone remains:

> Produce and validate a bootable qcow2 image in a VM.
