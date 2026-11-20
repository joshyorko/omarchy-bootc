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
  Run 44721708559 exposed separately rebuilt parent divergence despite successful
  lint/contracts. Staged builds now render only the relevant `FROM` boundary to
  the recorded immutable local image ID; all stage instructions remain unchanged.
  A tiny real Podman parent-binding probe runs in preflight before the compiler;
  the original DiffID prefix gate remains fatal.
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

- **P1-07 race reproduced at bc6eff9:** a deterministic parent-replacement fixture
  copies an outside-home dummy file after `ensure_safe_home_path` returns.
  The guard before root `cp`/`mv` is not race-safe confinement. The local
  reproducer and receipt are in `output/acceptance-evidence/adoption-race/`.
  The repair routes backup, restore, seeding and rollback through the installed
  `omarchy-adoption-filesystem.py` helper: component-by-component no-follow
  descriptor traversal, descriptor-relative recursion, and no-clobber publication.
  Local race and preservation tests pass. Hosted real-root run 44728719656 passed
  descriptor races, UID/GID handling and adoption retry/skills preservation on
  bba1c8f. Hosted run 44729355664 passed real separate-mount EXDEV move,
  no-clobber, metadata, restore and rollback coverage at d31a69f; a new image/guest
  qualification remains required before this gate can be closed.

### Apps launcher runtime diagnosis

Run [44726778692](https://github.com/joshyorko/omarchy-bootc/actions/runs/44726778692)
built bc6eff9 successfully and booted the installed guest with KVM. Native plugin
and persistence checks passed, but upstream acceptance stopped at the 15-second
Apps visibility wait, before lifecycle qualification. The retained
`failure-apps-menu-opens.png` visibly shows the application grid. At pinned upstream
ac2690c, `default/omarchy/omarchy-menu.jsonc` routes Apps to `omarchy.dock apps`,
and `shell/plugins/dock/AppGrid.qml` declares `omarchy-dock-apps`; the test instead
waited for the dismissed `omarchy-menu` layer.

The checksum-guarded adapter now checks the exact dock-grid namespace for open
and close. Search, actual Omawrite window launch/closure, screenshots and all
original deadlines remain required. The focused behavioral regression rejects
the old assertion, a missing grid and a missing writer window. This is harness
evidence, not a new guest pass. A fresh full image must include the later adoption
repair before it can qualify.

Small selected logs/PNGs and the parent manifest receipt are retained under
`output/acceptance-evidence/menu-44726778692/`; the complete remote evidence is
[artifact 14627268528](https://github.com/joshyorko/omarchy-bootc/actions/runs/44726778692/artifacts/14627268528).

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
