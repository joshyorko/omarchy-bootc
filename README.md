# Omarchy Quattro on bootc

This repository builds the official Omarchy Quattro userspace and desktop as an Arch bootc OCI image.

## Architecture

- Omarchy stable owns the complete Arch `core`, `extra`, `multilib`, and `omarchy` package universe.
- The final root starts empty and is populated with pacman against the official Omarchy stable topology.
- Bootcrew mono supplies the reviewed Arch-on-bootc construction and filesystem semantics, not a package payload or final base image.
- Bootc owns deployments, the boot filesystem, initramfs, image upgrades, and rollback.
- Official `omarchy`, `omarchy-settings`, package manifests, commands, themes, configs, shell, and desktop payloads are installed without local replacements.

The build never inherits Bootcrew's published rolling image and never downgrades an already-built Arch root with `pacman -Syyuu`.

## Pinned construction inputs

- Disposable Arch bootstrap tool: `docker.io/archlinux/archlinux:latest@sha256:0de35fe2ee793494ccfc99b202f6b30215b078baf2b082e9ccb027840c534fc1`
- Bootcrew mono: `5f048fa65a94daefc814d3cdd941d8d1e113c09e`
- bootc v1.16.10 source: `3e76c16556c55e6d15d31bd47602b231e2131cb2`
- Omarchy v4.0.1: `13f18b2cb7286fb54f87daf571a031aa6af3d8f0`
- Omarchy packages: `f448847d1f6e664038636542502354a388cb0f94`
- Official Omarchy ISO Quattro reference: `268bac16d351a21d867e37565738f458b11cb06c`

The disposable Arch image is only the pacman execution environment. None of its installed package files enter the final root. The final OCI records the Bootcrew and bootc revisions in labels and under `/usr/share/omarchy-bootc/sources/`.

## Repository layout

```text
<<<<<<< HEAD
Containerfile                         empty-root and image-stage assembly
build/20-quattro.sh                  official Quattro package closure
build/25-quattro-user.sh             acceptance-only first-boot fixture
build/30-bootc-ownership.sh          evidenced lifecycle collision handling
build/verify-quattro-payload.sh      package ownership and projection proof
transition/omarchy-transition.sh      source-aware switch preflight and recovery
custom/first-boot/omarchy-adopt-existing-user.sh  bounded persistent-home adoption
custom/pacman/                       official stable repository topology
vendor/bootcrew/                     pinned construction snapshot and metadata
tests/test-quattro-source-contract.sh executable architecture contract
docs/installer-parity-contract.md    upstream-Omarchy ISO adapter contract
docs/transition-contract.md          cross-distro switch and mutable-state contract
=======
omarchy-bootc/
├── build/                              # image build-time scripts
├── custom/packages/                    # package lists
├── custom/greetd/config.toml           # greetd/agreety login command
├── custom/first-boot/omarchy-setup.sh  # root first-boot logic
├── custom/hypr/                        # staged Hyprland defaults
├── iso_files/                          # installer hook templates/scripts
├── .dagger/                            # Dagger pipeline code for validation and ISO builds
├── systemd/system/omarchy-firstboot.service
├── image/disk.toml                     # bootc-image-builder config
├── Justfile
└── docs/technical-status.md
>>>>>>> origin/main
```

## Local checks

<<<<<<< HEAD
Run repository-native checks on the Bluefin host; the image build itself runs in Podman and does not layer development packages onto the host.
=======
- `podman`
- `just`
- `jq`
- `machinectl` (required when the native disk-image recipes need to copy a rootless-built image into rootful podman)
- `dagger` (required for local installer ISO builds)
- `sudo` (for rootful bootc-image-builder)
- `/dev/kvm` for practical VM boot testing

Run `just validate` before build.
Run `just validate-dagger` when you want the repo syntax checks executed inside the Dagger pipeline.
After editing `.dagger/main.go` or after a fresh Dagger scaffold, run `just dagger-develop` once from a host that can start the Dagger engine. That regenerates the Go SDK support files (`.dagger/internal/**`, `.dagger/dagger.gen.go`, `go.sum`) expected by Dagger's Go module layout.

## Local build + VM smoke test
>>>>>>> origin/main

```bash
just test-contract
just test-transition
just validate
just lint
just build
```

For the legacy direct disk-image path:

```bash
just build-qcow2
just run-vm
```

`just validate` reports whether KVM is available. Software emulation is possible but is not equivalent evidence for final desktop acceptance.

## Publishable and acceptance images

The publishable `final` target contains no default user, known password, or passwordless sudo rule. Test credentials exist only in the non-publishable `acceptance` target. On the installed VM, its first-boot fixture creates the user after official `/etc/skel` exists and invokes package-owned `omarchy-provision-user --first-install`.

No release claim is made until the OCI passes fatal `bootc container lint`, installs to disk, reaches official SDDM and the official Quattro Hyprland/Quickshell session, passes desktop behavior checks, and completes a two-image bootc upgrade and rollback cycle.

## Cross-distro bootc switch

<<<<<<< HEAD
Cross-distro switching is a separate state transition, not a raw image swap.
The supported source profiles are Bluefin, Dakota, and existing Omarchy bootc.
Run the source-side helper from this checkout before switching:

```bash
sudo ./transition/omarchy-transition.sh preflight <target-image>
sudo ./transition/omarchy-transition.sh capture-state
sudo ./transition/omarchy-transition.sh backup
sudo ./transition/omarchy-transition.sh apply --confirm <target-image>
=======
For local installer testing, keep the disk-image and installer flows separate. The ISO build is Dagger-owned locally and in CI:

```bash
# One-time after Dagger module edits or fresh checkout if generated SDK files are missing.
just dagger-develop

# Build the installer ISO into output/iso/.
just build-iso-local

# Boot the newest output/*.iso through the same browser VM UI as just run-vm.
just run-installer-iso
>>>>>>> origin/main
```

Reboot after the explicit `bootc switch`. On first Quattro boot, an existing
`/var/home` user enters the bounded adoption service. Fresh ISO installs write
an installer-origin marker and stay on the upstream Omarchy provisioning path.
Use `sudo omarchy-adoption-rollback` only when intentionally recovering the
mutable user-state transition; it preserves post-adoption files separately
because bootc rollback does not roll back `/var/home`. Unknown source systems
are refused. See [the transition contract](docs/transition-contract.md).

## Installer boundary

Existing Dudley, Dakota, and Bluefin installer variants remain independent and keep their prescribed implementations. The future Quattro ISO path belongs in `dudley-iso` as an additive variant based on pinned `omacom-io/omarchy-iso`.

That adapter preserves the official configurator, storage/encryption UX, dashboard, provisioning, SDDM setup, and upstream acceptance harness. It replaces only pacstrap/Limine/mutable-root deployment with `bootc install to-filesystem` and bootc finalization. See [the installer parity contract](docs/installer-parity-contract.md).

## Explicit boundary

`omarchy update` integration is not implemented. Read-only design work identifies `omarchy-update-system-pkgs` as a possible upstream backend seam, but desktop, installer, and bootc lifecycle acceptance come first.
