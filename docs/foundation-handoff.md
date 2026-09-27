# Immutable foundation handoff

The `foundation` target is the lower-stage boundary for the selected Bootcrew, Arch, bootc, SELinux, coreutils, and native-composefs tuple. The dedicated workflow in `.github/workflows/foundation.yml` builds only this target.

It checks out the exact pull-request head (or the explicitly selected workflow-dispatch ref), runs the existing `scripts/ci/candidate-build.sh foundation` target, and then verifies the generated receipt against the OCI archive:

- the receipt source SHA equals the checked-out commit;
- the recorded bootc and Bootcrew pins are the selected values;
- the Podman image ID is an immutable 64-hex identity;
- the OCI manifest digest in `index.json` matches the receipt;
- the archive SHA-256 matches the receipt.

The uploaded `omarchy-bootc-foundation-<source-sha>` artifact contains the verified OCI archive and its receipt. It is an immutable handoff for the separate Omarchy assembly stage, not a complete OS candidate and not runtime or VM acceptance evidence. Assembly must consume the handoff only after this workflow is green; the normal full-image and acceptance workflows remain unchanged.
