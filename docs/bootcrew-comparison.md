# bootcrew reference comparison (Arch bootc)

Summary of how bootcrew ships real `bootc` on Arch and how this repository differs.

## How bootcrew delivers bootc on Arch

- Builds `bootc` from source inside the image build: installs `make git rust go-md2man`, clones `bootc-dev/bootc`, and `make -C ... bin install-all` (bootcrew/arch-bootc `Containerfile`; same flow split into builder stage in `bootcrew/mono/arch/Containerfile` + `shared/build.sh`).
- Configures initramfs for bootc: writes dracut drop-ins to add the `bootc` module and rebuilds initramfs during the image build (`bootcrew/arch-bootc: dracut.conf.d/30-bootcrew-*.conf` + `dracut --force`; `bootcrew/mono/shared/initramfs.sh`).
- Prepares the sysroot for bootc/composefs: relocates `/var` content under `/usr/lib/sysimage`, rewrites pacman DB paths, sets HOME to `/var/home`, adds tmpfiles entries, enables composefs/readonly sysroot via `prepare-root.conf`, and prunes legacy mutable dirs (`bootcrew/arch-bootc Containerfile`; `bootcrew/mono/shared/bootc-rootfs.sh`).
- Ships boot-critical tooling directly in the image: `base`, `dracut`, kernel, `ostree`, `skopeo`, `podman`, filesystems, etc.; then runs `bootc container lint` and sets `LABEL containers.bootc 1` (arch-bootc Containerfile; mono arch Containerfile).
- Bootable image generation uses bootc itself: `just generate-bootable-image` runs `bootc install ... --composefs-backend --via-loopback` on the built image (bootcrew/arch-bootc `Justfile`).

## How omarchy-bootc differs today

- bootc is built from source in-image (default `BOOTC_REF=v1.13.0`), dracut drop-ins add the `bootc` module, and initramfs is rebuilt during the image build.
- Sysroot/pacman layout matches bootcrew: `/usr/lib/sysimage` pacman paths, `/var` as mutable prefix, `HOME=/var/home`, composefs enabled via `prepare-root.conf`, tmpfiles for mutable dirs.
- `bootc container lint` and `containers.bootc=1` label are now applied.
- Primary qcow2 path uses `bootc install --composefs-backend --via-loopback` (raw then qcow2 via `qemu-img`); legacy bootc-image-builder remains as `build-qcow2-bib`.
- Omarchy desktop/session customizations remain on top of the bootcrew-aligned bootc base.

## What blocks real bootc integration here

- Coverage for bootc lifecycle (upgrade/rebase/rollback) on Arch remains missing.
- Host dependency on `qemu-img` for qcow2 conversion after `bootc install` (raw output is first-class).
- Validation across host/container runtimes for the new bootc install-to-disk path still needs to be broadened.

## Smallest next step to align safely

- Add automated bootc lifecycle tests (rebase/rollback) against the composefs/ostree sysroot.
- Track and periodically refresh the pinned `BOOTC_REF` while keeping lint/install runs green.
- Decide when to retire the bootc-image-builder fallback once the native bootc install path is stable in CI.
