# omarchy-bootc

An **Arch Linux**-based [bootc](https://github.com/bootc-dev/bootc) proof-of-concept image for
[Omarchy](https://github.com/basecamp/omarchy)-compatible immutable desktops.

Repository structure inspired by [@projectbluefin/finpilot](https://github.com/projectbluefin/finpilot).
**Does not use Fedora, Bluefin, Silverblue, CentOS, GNOME OS, or dnf5.**

---

## Table of Contents

1. [Overview](#overview)
2. [Repository layout](#repository-layout)
3. [Prerequisites](#prerequisites)
4. [Local build & test workflow](#local-build--test-workflow)
5. [GitHub Actions enablement](#github-actions-enablement)
6. [GHCR publish setup](#ghcr-publish-setup)
7. [Optional: image signing with cosign](#optional-image-signing-with-cosign)
8. [Optional: SBOM generation](#optional-sbom-generation)
9. [Customisation guide](#customisation-guide)
10. [Architecture & design decisions](#architecture--design-decisions)

---

## Overview

`omarchy-bootc` builds an OCI container image on top of `archlinux:base` with:

* **bootc** for declarative, image-based OS updates
* **Hyprland** Wayland compositor (packages in `custom/packages/omarchy.packages` — currently placeholders)
* **Catppuccin Mocha** theming skeleton
* A **first-boot** service that performs one-time user setup after VM deployment
* A **Justfile** for the full local workflow: build OCI → generate qcow2 → run VM

---

## Repository layout

```
omarchy-bootc/
├── .github/
│   └── workflows/
│       ├── build.yml                  # Build & publish to GHCR
│       └── validate-shellcheck.yml    # Lint shell scripts
├── build/
│   ├── 10-base.sh                     # Core packages (pacman)
│   ├── 20-omarchy.sh                  # Hyprland / Omarchy packages (placeholder)
│   ├── 30-services.sh                 # systemd service enablement
│   └── README.md
├── custom/
│   ├── packages/
│   │   ├── base.packages              # Core package list
│   │   └── omarchy.packages           # Hyprland / Omarchy packages (placeholder)
│   ├── hypr/
│   │   └── hyprland.conf.example      # Hyprland config skeleton
│   └── first-boot/
│       └── omarchy-setup.sh           # First-boot user-layer setup
├── image/
│   └── disk.toml                      # bootc-image-builder config (qcow2)
├── systemd/
│   └── system/
│       └── omarchy-firstboot.service  # One-shot first-boot systemd unit
├── Containerfile                      # Multi-stage OCI image definition
├── Justfile                           # Local workflow automation
└── README.md
```

### Separation of concerns

| Layer | Where | Runs |
|---|---|---|
| Build-time OS customisation | `build/*.sh`, `custom/packages/` | During `podman build` |
| First-boot user setup | `custom/first-boot/`, `systemd/` | Once on first VM boot |
| Runtime / user-layer tooling | flatpak, homebrew, dotfiles | After login |

---

## Prerequisites

| Tool | Min version | Notes |
|---|---|---|
| `podman` | 4.x | Local OCI builds |
| `just` | 1.x | Task runner (`pacman -S just` or `cargo install just`) |
| `sudo` | — | Required for bootc-image-builder |
| `jq` | — | Used by the Justfile image-copy helper |
| `qemu` / KVM | — | Running VMs locally (`/dev/kvm` must be accessible) |
| `ss` | — | Port-conflict check in Justfile (`iproute2`) |

For VM output generation, `bootc-image-builder` (BIB) is pulled automatically as
`quay.io/centos-bootc/bootc-image-builder:latest`.  It requires `--privileged`
podman access (i.e. `sudo podman`).

---

## Local build & test workflow

```bash
# 1 — Clone and enter the repo
git clone https://github.com/joshyorko/omarchy-bootc
cd omarchy-bootc

# 2 — Build the OCI container image
just build

# 3 — Generate a bootable qcow2 VM image (requires sudo + KVM)
just build-qcow2
# Output: output/qcow2/disk.qcow2

# 4 — Launch the VM in your browser via qemux/qemu
just run-vm
# Opens http://localhost:8006 after ~30 s

# Alternatively, rebuild OCI + qcow2 in one step:
just rebuild-qcow2

# Lint all shell scripts
just lint
```

> **Tip:** If you only want to test the container image itself (without converting
> to qcow2), run `podman run --rm -it localhost/omarchy-bootc:stable bash`.

---

## GitHub Actions enablement

The workflow in `.github/workflows/build.yml` triggers on:

* Every push to `main`
* Every pull request targeting `main`
* A daily schedule (10:05 UTC)
* Manual dispatch (`workflow_dispatch`)

No additional secrets are needed for the basic build.  The workflow:
1. Checks out the repo
2. Builds the OCI image with `buildah`
3. Pushes to GHCR on pushes to `main` (not on PRs)

To **enable** the workflow, simply push this repository to GitHub.  The
`GITHUB_TOKEN` secret is provided automatically by Actions.

---

## GHCR publish setup

The workflow publishes to `ghcr.io/<OWNER>/omarchy-bootc:stable` automatically.

1. **Enable package write permissions** — in your repo Settings → Actions →
   General → Workflow permissions, select *Read and write permissions*.
2. **Make the package public** (optional) — after the first successful push,
   navigate to the generated package on your profile and set its visibility.

To pull the published image:

```bash
podman pull ghcr.io/<OWNER>/omarchy-bootc:stable
```

To switch a running bootc system to this image:

```bash
sudo bootc switch ghcr.io/<OWNER>/omarchy-bootc:stable
```

---

## Optional: image signing with cosign

> Disabled by default.  Uncomment the relevant steps in `build.yml` to enable.

1. Generate a key pair locally:

   ```bash
   cosign generate-key-pair
   ```

2. Add `COSIGN_PRIVATE_KEY` as a repository secret
   (Settings → Secrets and variables → Actions → New repository secret).

3. Commit `cosign.pub` to the repository root.

4. Uncomment the `Install Cosign` and `Sign container image` steps in
   `.github/workflows/build.yml`.

Consumers can then verify images with:

```bash
cosign verify --key cosign.pub ghcr.io/<OWNER>/omarchy-bootc:stable
```

---

## Optional: SBOM generation

> Disabled by default.  Requires image signing to be enabled first.

The workflow includes commented-out steps for [Syft](https://github.com/anchore/syft)
SBOM generation and cosign attestation.  To enable:

1. Enable image signing (see above).
2. Uncomment the `Setup Syft`, `Generate SBOM`, and `Add SBOM Attestation`
   steps in `.github/workflows/build.yml`.

---

## Customisation guide

### Adding packages

Edit the package lists in `custom/packages/`:

```
custom/packages/base.packages      ← installed by build/10-base.sh
custom/packages/omarchy.packages   ← installed by build/20-omarchy.sh
```

One package name per line; `#` lines and blank lines are ignored.  All packages
must be available in the official Arch repositories.  For AUR packages, add a
build step that installs `yay` or compiles the PKGBUILD directly.

### Adding Hyprland / Omarchy config

1. Populate `custom/hypr/hyprland.conf.example` with your Hyprland config.
2. Uncomment and populate `custom/packages/omarchy.packages`.
3. Extend `custom/first-boot/omarchy-setup.sh` with any user-specific setup
   (dotfile deployment, theme application, etc.).

### Adding a new build step

Create a numbered script under `build/` (e.g. `build/40-fonts.sh`) and add
the corresponding `RUN` directive to `Containerfile`:

```dockerfile
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/40-fonts.sh
```

### Pinning the base image

For reproducible builds, replace the `FROM archlinux:base` line with a
pinned digest:

```dockerfile
FROM archlinux:base@sha256:<digest>
```

Use `podman inspect archlinux:base --format '{{.Digest}}'` to obtain the digest.

---

## Architecture & design decisions

### Why Arch Linux?

Omarchy targets Arch Linux as its native platform.  Using `archlinux:base` as
the OCI base means the resulting immutable image ships the same packages and
ABI that Omarchy was developed against.

### Why bootc?

`bootc` provides atomic, image-based OS upgrades without the RPM dependency.
Users run `bootc upgrade` to get the latest image rather than `pacman -Syu`,
preserving the declarative, reproducible nature of the image.

### Pacman DB relocation

The standard Arch pacman database lives under `/var/lib/pacman`.  In a bootc /
ostree system, `/var` is **ephemeral user-data** that is not included in the
deployed image.  The `Containerfile` relocates the database to
`/usr/lib/sysimage/pacman` (an ostree convention) so package metadata survives
image upgrades.

### BuildStream

BuildStream is **intentionally deferred for v1**.  The current build pipeline
(Containerfile + Justfile + GitHub Actions) is sufficient to produce a working
VM image.  BuildStream integration may be introduced in a future release if
more complex multi-stage build orchestration is required.

### BIB (bootc-image-builder)

`bootc-image-builder` (`quay.io/centos-bootc/bootc-image-builder`) converts
any bootc-compatible OCI image into a bootable disk image (qcow2, raw, ISO)
regardless of the OS inside the container.  The `image/disk.toml` config
targets a 20 GiB qcow2 — the recommended format for the first working VM.
