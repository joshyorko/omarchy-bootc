# Technical status: Omarchy Quattro bootc

_Last updated: 2026-11-18_

## Architecture of record

The final image is an Omarchy-stable empty-root build. A digest-pinned current Arch container runs pacman against Omarchy's stable repositories and populates `/stable-root`; no package from the bootstrap container crosses into that root.
- Build scripts are layered and wired from `Containerfile` with explicit boot-critical package lists.
- bootc is built from the pinned v1.16.13 source revision and dracut is rebuilt with the bootc module.
- Sysroot is prepared for bootc/composefs with pacman state under `/usr/lib/sysimage`.
- Local build and qcow2/run flows are defined in `Justfile`; legacy bootc-image-builder fallbacks remain available.
- Installer ISO generation is Dagger-owned and remains an explicit/manual path.
- Rootful/rootless image handoff is explicit for the native disk-image and VM smoke paths.
- The official SDDM session starts the packaged Quattro Hyprland/Quickshell desktop.

Bootcrew's published Arch image is not the final base and is not package authority. Bootcrew mono commit `5f048fa65a94daefc814d3cdd941d8d1e113c09e` is the source reference for pacman relocation, dracut, composefs, `/usr`/`/var`, tmpfiles, and bootc filesystem construction. Bootc is built from exact commit `fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60`; an unpinned clone is forbidden.

The acceptance target is latest stable Quattro RS `4.5.0-3`, upstream tag
`v4.5.0` at commit `ac2690cd7be4f47e4a255f5e2e78d904d436b068`.
The observed Quattro branch head `33e9f56c6d71a62bff6fdfbdf6dd3288b3ac46e5`
is distinct from that published release; it is not claimed as the package source.
The OS test fixture's upstream ISO reference is
`2d0b3ecdec2dd40c82cb8c3d6034b2ac5ab3ae92`; downstream Dudley remains separate.
Both official package archives were authenticated against pinned signer
`40DFB630FF42BCFFB047046CF0134EE680CAC571` before recording their SHA-256 pins.
The packaged version file, base and optional manifests, and `omarchy-version`
were compared byte-for-byte against that release commit. This is bounded payload
correspondence, not a claim to have reproduced the publisher's build.

The earlier `4.0.4-1` work remains diagnostic history. Candidate run `44307915565`
failed before foundation because the mutable index served `4.5.0-3` instead.
The shared archive helper now selects the authenticated target pair explicitly;
there is no latest-version fallback. The wider dependency closure still uses
live Omarchy stable databases. Two pinned archives do not imply a fully frozen
closure, reproducible image, or proven runtime compatibility.

## Upgrade and visual acceptance gap

The 4.5 suite retains every upstream file and adds real input-method/composition
and monitor-overlay tests. Only the existing root-filesystem and declared-kernel
assertions are adapted. The complete original suite is checksum guarded at the
new release commit; neither new test is waived. Optional upstream security
subchecks may still report skips and must not be promoted to PASS.

The VM harness captures the actual QEMU display over a private QMP Unix socket:
first boot, SDDM greeter with fixture autologin disabled, staged update, rebooted
B and rollback A. Native captures show a real terminal with version, package,
bootc, plugin and OMP selection data. Upstream menu/app/theme PNGs and native
PNGs are copied directly into runtime artifacts as well as retained in receipt
archives. These capture points are not evidence until the built candidate boots
and the corresponding images are inspected. The terminal uses a controlled OMP
launcher recorder; it does not prove a provider call.

Local capability probe: QEMU, qemu-img and virsh exist; virt-manager and
`/dev/kvm` are absent. Libvirt session access fails because its cache path is
read-only. A bounded diskless QEMU/TCG run verified PNG capture only. Expensive
OS acceptance remains hosted. The existing direct-to-disk smoke is not a GUI
installer: installer first screen/disk/progress/completion and Gate 6 remain
BLOCKED until an accepted exact image is available to downstream Dudley ISO.
No upstream ISO or stock qcow2 screenshot may stand in for our bootc evidence.

## Implemented in the current branch

- Official stable repository topology for `core`, `extra`, `multilib`, and `omarchy`.
- Empty-root base package resolution; no inherited rolling Bootcrew package state and no bulk downgrade.
- Recorded Bootcrew and bootc source URLs, revisions, vendored checksums, OCI labels, and in-image revision files.
- Official `omarchy-keyring`, `omarchy-settings=4.5.0-3`, `omarchy=4.5.0-3`, and the current Quattro `omarchy-base.packages` closure at revision `ac2690cd7be4f47e4a255f5e2e78d904d436b068`.
- Dependency-resolution report for `omarchy-other.packages` without installing mutually exclusive hardware stacks.
- Complete optional dependency resolution using the pinned official ISO's `arch-mact2` repository only in a temporary resolver config; the four-repository foundation remains unchanged.
- The current `arch-mact2` index omits `apple-bcm-firmware` still required by Omarchy. Resolve the checksum-pinned native `14.0-1` archive from that same configured mirror with `pacman -Up`, recording `resolvable-archive`, URL and checksum distinctly from indexed resolution. No extra repository is added, no hardware package is installed into the base, and the incompatible macOS-volume firmware fetcher is not substituted.
- Package provenance checks for commands, Quickshell, themes, `/etc/skel`, SDDM, and the canonical session file.
- One named `/usr/local` bootc projection exception for the package-owned session file, with byte-identity proof.
- Five observed Limine/mkinitcpio hooks shadowed and three observed snapshot units masked; `kernel-modules-hook` remains enabled and audited.
- Final dracut verification requires the bootc v1.16.13 `ostree` and `bootc` modules and both root-setup payloads; the correction is layered above the unmodified Bootcrew snapshot.
- Separate publishable and acceptance targets. The publishable image has no baked test account or unrestricted passwordless sudo rule; upstream command-scoped policies remain intact.
- Acceptance first boot invokes official `omarchy-provision-user --first-install`; local provisioning reimplementations remain forbidden.
- Cross-distro switching now uses structured strongest-to-weakest source evidence, persists the tracking ref and resolved digest, re-resolves immediately before `bootc switch`, and provides exact post-boot verification; the target adoption service retains independent mutable-state rollback.
- `omarchy update` and the update indicator now use the bootc-native `upgrade --check`/`upgrade` bridge; migrations are deferred to the first login after exact-digest verification.
- The upstream graphical PATH keeps `/usr/share/omarchy/bin` first; its three
  public update entry points (`omarchy`, `omarchy-update`, and
  `omarchy-update-available`) project to immutable bootc wrappers, while
  package-owned `/usr/bin` payloads remain intact.
- Privileged update state uses fixed image-owned `/run` and `/var/lib` paths; Gate 5 tracing is accepted only through a root-owned mode-0755 hook, so caller-controlled environment paths cannot redirect bootc or transaction writes.
- A scheduled/manual upstream Quattro tracker records drift as one advisory issue without repinning or publishing.

## Required publication evidence

- bootc lifecycle checks (upgrade/rebase/rollback) on this Arch-based image.
- Exact candidate and disposable overlay dependency checks execute before installation; native desktop, real registry A→B updater, finalization, and rollback remain hosted VM gates.
- Reliability of `bootc install to-disk --composefs-backend --via-loopback` across host/container runtimes; qcow2 conversion relies on host `qemu-img`.
- End-to-end VM reliability across host environments.
- End-to-end validation of the existing ISO installer flow, especially the Bluefin live rootfs -> omarchy target handoff.
- Dagger Go SDK regeneration and full `just build-iso-local` execution on a host with Docker/Dagger engine access.
- Desktop session quality/stability beyond first login.
- Long-term assumptions around pacman DB relocation and bootc source build behavior over time.

The following are gates, not inferred results:

1. Build the pinned empty-root foundation and prove `pacman -Qu` is empty.
2. Inspect exact Bootcrew and bootc revision labels and in-image source records.
3. Pass fatal `bootc container lint` on foundation, Quattro, acceptance, and final targets.
4. Install the acceptance OCI to disk and prove the first-boot finalizer marker and representative runtime-only setup.
5. Reach official SDDM and official `omarchy.desktop` Hyprland/Quickshell.
6. Exercise themes, menus, representative apps, shell behavior, and ordinary package-owned `omarchy-*` commands.
7. Boot a second OCI revision, verify the upgrade, roll back, reboot, and verify the original deployment.

Focused shell and source-contract checks do not substitute for assembled-image, VM, or lifecycle evidence.

## Installer status

The future Quattro path is a separate `dudley-iso` variant pinned to `omacom/omarchy-iso` Quattro commit `86c07785cb0f63be78edb1349843d5817b5c0e66`. Its contract is upstream Omarchy UX plus a narrow `bootc install to-filesystem` backend; Gate 6 remains out of scope for this repository.


See `docs/installer-parity-contract.md` for the normative installer and non-regression requirements.

## Deferred

- Hosted Podman/KVM assembled-image, plugin/OMP, A/B rollback, and Dakota round-trip evidence remain runtime gates; they are blocked when the required image registry, VM, or hypervisor capability is unavailable, never inferred from shell contracts.
- Gate 6 installer execution remains in `dudley-iso` and is not claimed by this repository.
- No installer UI fork or local reimplementation of Omarchy user provisioning.
- No arbitrary-source switch is accepted; Bluefin, Dakota, and existing Omarchy transitions still require clean VM evidence for adoption, independent recovery, and reverse rollback.
- No publication, ISO replacement, or claim of desktop/lifecycle completion before the gates above pass.
