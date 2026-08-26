# bootc delivery on Omarchy-stable Arch

_Last updated: 2026-08-26_

## Architecture of record

Bootc v1.16.10 is built inside the Omarchy-stable root from exact upstream commit `3e76c16556c55e6d15d31bd47602b231e2131cb2`.

The source URL, revision, exact fetch, commit-identity check, OCI label, and in-image source record are executable parts of the build contract. An unpinned clone or moving tag is not accepted.

## Why source build remains correct

- Omarchy stable does not currently provide the required bootc binary as part of its authoritative package universe.
- Building inside the stable root links against the same stable runtime dependency set shipped in the final OCI.
- The exact commit is independently reviewable and reproducible without importing a third-party Arch package universe.
- Fatal `bootc container lint`, install-to-disk proof, and lifecycle acceptance validate the resulting binary in the assembled image.

## Rejected delivery paths

- A rolling Bootcrew image would import a different Arch package universe before Quattro is installed.
- An unpinned upstream clone would make identical Containerfile inputs resolve to different bootc code.
- A bulk pacman downgrade would leave a difficult-to-audit mixed construction history.
- A third-party binary repository would add another package authority to the image.
- A locally published bootc package repository is unnecessary until repeated source builds demonstrate a concrete operational problem.

## Future refresh

Update bootc only as a source-pinned change with the revision metadata and contract in the same patch. The release gate remains: stable-root package closure, zero pending stable updates, exact source labels, fatal lint, bootc disk installation, and upgrade/rollback acceptance.

The future Omarchy ISO adapter uses `bootc install to-filesystem` because the upstream installer already owns storage and encryption UX. That installer contract is separate from how the bootc binary is delivered inside the OCI; see `docs/installer-parity-contract.md`.
