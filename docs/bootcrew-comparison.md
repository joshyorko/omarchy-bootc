# bootcrew reference comparison (Arch bootc)

Summary of how bootcrew ships real `bootc` on Arch and how this repository differs.

## How bootcrew delivers bootc on Arch

- Builds `bootc` from source inside the image build: installs `make git rust go-md2man`, clones `bootc-dev/bootc`, and `make -C ... bin install-all` (bootcrew/arch-bootc `Containerfile`; same flow split into builder stage in `bootcrew/mono/arch/Containerfile` + `shared/build.sh`).
- Configures initramfs for bootc: writes dracut drop-ins to add the `bootc` module and rebuilds initramfs during the image build (`bootcrew/arch-bootc: dracut.conf.d/30-bootcrew-*.conf` + `dracut --force`; `bootcrew/mono/shared/initramfs.sh`).
- Prepares the sysroot for bootc/composefs: relocates `/var` content under `/usr/lib/sysimage`, rewrites pacman DB paths, sets HOME to `/var/home`, adds tmpfiles entries, enables composefs/readonly sysroot via `prepare-root.conf`, and prunes legacy mutable dirs (`bootcrew/arch-bootc Containerfile`; `bootcrew/mono/shared/bootc-rootfs.sh`).
- Ships boot-critical tooling directly in the image: `base`, `dracut`, kernel, `ostree`, `skopeo`, `podman`, filesystems, etc.; then runs `bootc container lint` and sets `LABEL containers.bootc 1` (arch-bootc Containerfile; mono arch Containerfile).
- Bootable image generation uses bootc itself: `just generate-bootable-image` runs `bootc install ... --composefs-backend --via-loopback` on the built image (bootcrew/arch-bootc `Justfile`).

## How omarchy-bootc differs today

- bootc is intentionally not installed; the image relies on `bootc-image-builder` (CentOS container) to emit qcow2 output, not on `bootc install` from within the Arch image.
- Pacman DB is relocated only (to `/usr/lib/sysimage/pacman`); the rest of `/var` remains in place and composefs/ostree prep is not applied.
- Initramfs is not rebuilt with bootc modules; no dracut drop-ins for bootc are present.
- The image omits `bootc container lint` and the `containers.bootc=1` label because bootc itself is absent.
- Boot assumptions lean on bootc-image-builder (lsinitrd via `dracut` package) rather than the bootc-in-image workflow bootcrew uses.

## What blocks real bootc integration here

- No bootc binary/package in the Arch image, so we cannot run `bootc container lint` or `bootc install` from inside the image.
- No bootc-aware initramfs (dracut module) or composefs/ostree root prep, which bootcrew applies to make the image bootc-ready.
- Image metadata/labels and bootc lifecycle checks are missing because bootc is absent.

## Smallest next step to align safely

- Introduce an optional, pinned bootc-from-source builder stage (mirroring `bootcrew/mono`’s builder+system split) that can be toggled on for experiments without altering the default image flow. Pair it with gated dracut drop-ins to add the bootc module when bootc is present. Keep the current bootc-less default until the source build is validated in CI.
