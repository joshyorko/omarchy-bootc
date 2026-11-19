# Acceptance audit follow-up

Review baseline: `091fbd2eb35170808034cdfc4ff276a628777ed9`.
Source/regression evidence is not runtime acceptance. No merge, release or image
publication is authorized. Installer Gate 6 remains separate and unaccepted.

## Implemented, awaiting independent re-check / relevant runtime proof

- P1-01: publication promotes the accepted OCI archive with preserved digests,
  verifies remote raw manifest bytes before signing, and updates stream tags last.
  Build/test jobs have no package/OIDC write; publication is a trusted separate job.
- P1-02: Cosign verified-envelope streams are slurped; real-format regression
  fails before and passes after the change, including multiple/malformed envelopes.
- P1-06: producer workflow/run/head/job/artifact metadata is verified before
  download by immutable artifact ID. A live metadata-only check passes for the
  retained c2ddabe candidate. The shipped dependency verifier is no longer exempt.
- Warm-store closeout: archive manifest/config hashes and source/platform are
  checked against the receipt before Podman load; an unrelated pre-existing image
  cannot satisfy the recorded image identity.
- P2-03: qualification forces the Omarchy profile and lifecycle, uses a fresh
  evidence directory, and requires native/reboot/lifecycle/status/PNG receipts.
- P2-04: shipped dependency-verifier changes fail the reuse regression.
- P2-07: package/OIDC credentials are confined to trusted publication; status writes
  are separate reporter jobs, not the runtime job. Unneeded ISO OIDC/inherit removed.
- P2-09: engine image digest/ID, bind mount and cgroup limits are checked together.
- P2-10: the common host-runtime boundary holds a host-wide runtime lock.

## Open blockers, in execution order

1. P1-03: bind all ISO paths to verified immutable image + source, with a separate
   intended tracking stream that does not freeze future updates.
2. P1-04: restore initial-account UI/flow or withdraw the legacy ISO until a real
   blank-media first-login acceptance pass exists.
3. P1-05: move local pacman private signing keys into ephemeral build-only storage;
   scan every exported layer, not only the final merged filesystem.
4. P1-07/P1-08/P1-09: confine home mutations to the intended user; freeze the
   present/absent baseline across retries; seed required missing desktop files.
   Preserve existing Gemini/Hermes skills as well as the currently listed agents.
5. P1-10 and updater closeout: bind/check staging identity and contain unexpected
   stages before any reboot or success receipt; retain intended channel semantics.
6. P1-11: disable wildcard networkd Ethernet ownership when enabling NetworkManager.
7. P1-12: compare booted Dakota overlay digest to that actual payload; retain base
   digest separately for tracking/provenance.
8. P1-13: fix duplicated first key during menu focus handoff; assert one first
   character and the expected Keybindings result on HEADLESS-2.
9. P2-01: crop notification OCR from measured layer bounds. Retained first frame
   is negative; latest pixels visibly contain the literal text missed by desktop OCR.
10. P2-02: compare preservation UID/GID/checksums before Gate 4 success; a skipped
    root adoption fixture must not be represented as recovery proof.
11. P2-05: bind/verify actual stage ancestry and accurately name verification siblings.
12. P2-06: resolve pacman's configured DBPath and require nonempty expected DB hashes.
13. P2-08/P2-11: avoid unused intermediate exports and duplicate final archives;
    budget graph/export stores and allowlist failure evidence instead of whole disks.
14. Confirm installed signature policy for future channel updates.

Only after those blockers: real graphical/KVM + A/B rollback qualification, then
bounded Dagger parity/cold-warm OCI measurements. Keep independent hosted checks.

## Infrastructure constraint

Exactly one builder was verified running after consolidation: omarchy-ac-0b534,
unchanged at 6 vCPU / 16 GiB RAM / 200 GiB disk. homebrew-t-18140 was powered off
with its 200 GiB PVC still Bound. Preserve both disks/caches; no new VM or parallel
heavy build is authorized. Dakota remains control-plane/source-check-only.
