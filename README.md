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
Containerfile                         empty-root and image-stage assembly
build/20-quattro.sh                  official Quattro package closure
build/25-quattro-user.sh             acceptance-only first-boot fixture
build/30-bootc-ownership.sh          evidenced lifecycle collision handling
build/verify-quattro-payload.sh      package ownership and projection proof
custom/pacman/                       official stable repository topology
vendor/bootcrew/                     pinned construction snapshot and metadata
tests/test-quattro-source-contract.sh executable architecture contract
docs/installer-parity-contract.md    future upstream-Omarchy ISO adapter contract
```

## Local checks

Run repository-native checks on the Bluefin host; the image build itself runs in Podman and does not layer development packages onto the host.

```bash
just test-contract
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

## Installer boundary

Existing Dudley, Dakota, and Bluefin installer variants remain independent and keep their prescribed implementations. The future Quattro ISO path belongs in `dudley-iso` as an additive variant based on pinned `omacom-io/omarchy-iso`.

That adapter preserves the official configurator, storage/encryption UX, dashboard, provisioning, SDDM setup, and upstream acceptance harness. It replaces only pacstrap/Limine/mutable-root deployment with `bootc install to-filesystem` and bootc finalization. See [the installer parity contract](docs/installer-parity-contract.md).

## Explicit boundary

`omarchy update` integration is not implemented. Read-only design work identifies `omarchy-update-system-pkgs` as a possible upstream backend seam, but desktop, installer, and bootc lifecycle acceptance come first.
