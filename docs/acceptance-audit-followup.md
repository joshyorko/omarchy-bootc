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
- P1-03: ISO workflows, Dagger `BuildIso`/`RenderIsoHooks`, `Justfile`, and
  `iso_files/configure_iso_anaconda.sh.in` bind installation to a verified
  immutable `@sha256:` image + exact attested source SHA, and write a separate
  mutable tracking stream into `bootc switch --mutate-in-place` so future updates
  are not frozen.
- P1-04: Anaconda initial-account creation UI (`UserSpoke`, `PasswordSpoke`,
  `anaconda-screen-accounts`) is restored and `%post` writes
  `/var/lib/omarchy-bootc/installer-origin`. Blank-media Gate 6 first-login
  acceptance remains separate and unaccepted.
- P1-05: pacman local signing keys are created exclusively on build-only tmpfs
  `/etc/pacman.d/gnupg`; public trust is exported/restored via
  `build/pacman-public-keyring.sh` (`--import-options import-local-sigs` +
  `--check-trustdb`) with zero secret material; `scripts/ci/verify-candidate-archive.py`
  scans every exported OCI layer blob (not only the merged filesystem) and runs
  automatically during candidate export.
- P1-06: producer workflow/run/head/job/artifact metadata is verified before
  download by immutable artifact ID. A live metadata-only check passes for the
  retained c2ddabe candidate. The shipped dependency verifier is no longer exempt.
- P1-07/P1-08/P1-09: `custom/first-boot/omarchy-adopt-existing-user.sh` confines
  all home reads/mutations inside the intended user's real home (refusing
  symlinked ancestors and preserving `$uid:$gid` ownership), freezes the
  present/absent baseline once per run (`baseline.tsv` + `baseline.done`) across
  retries, preserves `.gemini/skills`, `.hermes/skills`, and
  `.hermes/profiles/*/skills`, and seeds required missing desktop files generated
  by provisioning without overwriting existing user files.
- P1-10: `custom/bootc/omarchy-bootc-update` uses `bootc upgrade --download-only`,
  verifies the downloaded digest and `downloadOnly == true` before unlocking via
  `bootc upgrade --from-downloaded`, keeps unexpected moving-tag stages locked and
  cleans up markers on mismatch, and retains intended channel semantics.
- P1-11: `build/30-bootc-ownership.sh` masks `systemd-networkd.{service,socket}`
  and `systemd-networkd-wait-online.service` and removes
  `/usr/lib/systemd/network/20-wired.network` once NetworkManager is enabled;
  `build/acceptance-dependencies.sh` enforces this invariant.
- P1-12: `scripts/ci/dakota-roundtrip.sh` compares the booted Dakota overlay
  digest against the actual installed `${overlay_digest}` payload and retains the
  base Dakota release digest separately (`dakota-base-digest.txt`).
- P1-13: guarded `Menu.qml` patch establishes focus on `contentRevealed`/screen
  change, defers `loadProvidersForSearch()` via `Qt.callLater`, and suppresses
  spurious auto-repeat printable keys during opening focus handoff;
  `overlay-monitor-test.sh` rejects duplicated first characters / `No matches` and
  asserts an actual `Keybindings` menu match on `HEADLESS-2` and after recovery.
- Warm-store closeout: archive manifest/config hashes and source/platform are
  checked against the receipt before Podman load; an unrelated pre-existing image
  cannot satisfy the recorded image identity.
- P2-01: `screen_contains` crops notification OCR from measured
  `omarchy-notifications` layer bounds (`hyprctl -j monitors` + `hyprctl -j layers`)
  while preserving full-desktop diagnostics and OCR error propagation.
- P2-02: `scripts/ci/dakota-roundtrip.sh` compares source UID/GID/SHA-256
  preservation on both forward and reverse switches and refuses skipped adoption
  recovery fixtures (`test-adoption-resume.sh` no longer skips for non-root).
- P2-03: qualification forces the Omarchy profile and lifecycle, uses a fresh
  evidence directory, and requires native/reboot/lifecycle/status/PNG receipts.
- P2-04: shipped dependency-verifier changes fail the reuse regression.
- P2-05: `scripts/ci/candidate-build.sh` explicitly names `foundation` as a
  verification sibling of `quattro-assembly` off `bootcrew-system` and verifies
  OCI `RootFS.Layers` DiffID prefix ancestry across every stage.
- P2-06: `Containerfile` and `build/20-quattro.sh` resolve `pacman-conf DBPath`
  and require nonempty repository database SHA-256 provenance including expected
  databases (`core.db`, `extra.db`, and `omarchy.db`).
- P2-07: package/OIDC credentials are confined to trusted publication; status writes
  are separate reporter jobs, not the runtime job. Unneeded ISO OIDC/inherit removed.
- P2-08/P2-11: intermediate stages write lightweight receipts instead of unused
  multi-GiB `.oci.tar` exports, `dagger-candidate.sh` moves instead of duplicating
  the final archive, `candidate-build.sh` budgets both Podman graphroot and export
  stores, and runtime uploads exclude disk images (`*.raw`/`*.qcow2`/`*.img`/`*.oci.tar`).
- P2-09: engine image digest/ID, bind mount and cgroup limits are checked together.
- P2-10: the common host-runtime boundary holds a host-wide runtime lock.
- Signature policy (#14): `build/install-bootc-update.sh` installs an explicit
  fail-closed `/etc/containers/policy.json` (`default: [{"type":"reject"}]`) and
  `/etc/containers/registries.d/omarchy-bootc.yaml` (`use-sigstore-attachments: true`),
  and `omarchy-bootc-update` verifies `ghcr.io/joshyorko/omarchy-bootc` channel
  digests with `cosign verify` against the pinned GitHub Actions workflow OIDC
  identity when `cosign` is present (containers/image `skopeo` does not yet
  implement `subjectURI` in `policy.json` for keyless workflow SANs).

## Remaining gates (require real runtime execution)

1. Hosted exact-head OCI candidate build + per-layer secret scan + hosted QEMU
   graphical/desktop/notification/menu + native plugin/OMP + A->B update & rollback
   qualification on the integrated head.
2. Separate Gate 4 Dakota round-trip and Gate 6 blank-media ISO first-login
   acceptance after the accepted candidate exists.
3. Bounded Dagger parity / cold-warm OCI measurements after graphical acceptance.

## Infrastructure constraint

After owner authorization to resize for available capacity, omarchy-ac-0b534 was
resized to 4 vCPU / 8 GiB guest RAM / unchanged 200 GiB disk, with a two-CPU host
quota. Its VMI was verified Running and Ready. Harvester applies its configured
overcommit policy to requests; verify admitted pod reservations, not only the VM
template. The engine is capped at two CPUs / 5 GiB RAM / 6 GiB including swap.
homebrew-t-18140 remains stopped with its 200 GiB PVC Bound. The separate
day-job VM devsy-shared-harvester-4f954 remains unchanged. Preserve all disks and
caches; no new VM or parallel heavy build is authorized. Dakota remains
control-plane/source-check-only.
