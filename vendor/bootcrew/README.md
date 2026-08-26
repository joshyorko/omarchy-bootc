# Bootcrew construction snapshot

These files record the Arch construction imported from `bootcrew/mono` commit `5f048fa65a94daefc814d3cdd941d8d1e113c09e`.

- `SOURCE` and `REVISION` identify the reviewed Bootcrew source.
- `UPSTREAM_SHA256SUMS` records the three files as fetched from that commit.
- `SHA256SUMS` records the exact files consumed by this build.
- `shared/initramfs.sh` is byte-identical to upstream.
- `shared/bootc-rootfs.sh` differs only by removal of one terminal blank line.
- `shared/build.sh` contains the required compatibility patch: Bootcrew's unpinned clone is replaced with a shallow fetch of the exact `BOOTC_REVISION` from the explicit `BOOTC_SOURCE`, followed by a commit-identity check.

No package payload is imported from Bootcrew's published rolling image. Bootcrew is the construction reference; Omarchy stable resolves every package in the final Arch root.
