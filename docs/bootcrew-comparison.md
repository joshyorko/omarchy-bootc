# Bootcrew mono construction reference

## Decision

Bootcrew mono is the source reference for Arch-on-bootc construction. Its published rolling image is neither the final base nor package authority for Omarchy Quattro.

The build starts from an empty root resolved entirely against Omarchy stable, then applies the construction reviewed at `bootcrew/mono` commit `5f048fa65a94daefc814d3cdd941d8d1e113c09e`.

## Construction retained

- Relocate pacman-managed mutable state beneath `/usr/lib/sysimage`.
- Install the bootc runtime, kernel, dracut, OSTree, filesystem tooling, and boot-critical services from the same Omarchy-stable package universe.
- Generate a reproducible non-host-only dracut initramfs with the bootc module.
- Establish Bootcrew's `/usr` and `/var` filesystem model, including `/usr/local -> ../var/usrlocal`.
- The Quattro layer materializes `/usr/local` as an immutable image directory before package installation and retains it as image-owned dispatch after assembly.
- Enable composefs and a read-only sysroot.
- Create the mutable-directory tmpfiles contract.
- Run fatal `bootc container lint` before layering Quattro.

The reviewed source files, origin metadata, upstream checksums, and exact consumed checksums live under `vendor/bootcrew/`.

## Deliberate source delta

Upstream Bootcrew's `shared/build.sh` clones the default bootc branch. This repository replaces only that source acquisition with a shallow fetch of bootc commit `fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60` from `https://github.com/bootc-dev/bootc.git`, detaches at the fetched commit, and verifies `HEAD` exactly before building.

The delta is recorded in `vendor/bootcrew/README.md`. It is required by the source-pin contract and is not an Omarchy adaptation.

## Package-authority difference

Bootcrew's rolling image resolves against its current Arch repositories. The Quattro image cannot inherit that package state because Omarchy stable may intentionally lag current Arch as one internally consistent repository snapshot.

This repository therefore uses a digest-pinned current Arch image only as a disposable pacman executable. Pacman populates `/stable-root` from Omarchy stable before any Bootcrew construction step runs. No package file from the disposable image enters the final root, and no downgrade transaction repairs a mixed root afterward.

## Refresh rule

A Bootcrew refresh must update the source revision, vendored files, upstream and consumed checksums, Containerfile argument, executable contract, OCI source records, and full foundation build together. A bootc refresh must likewise update its exact commit, version evidence, source record, contract, and assembled-image verification together.
