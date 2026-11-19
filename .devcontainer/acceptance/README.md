# Harvester development shell and shared Dagger pipeline

The owned Harvester VM is Ubuntu 24.04, matching the GitHub runner OS family.
This optional shell uses `ghcr.io/ublue-os/devcontainer:latest`, matching Dudley
OS. It is not the build runner OS. Actual Dagger workers use Ubuntu 24.04;
privileged bootc installation and QEMU run on the Ubuntu host until nested
capability equivalence is proven. Do not install a Bluefin desktop on the VM.

The control-plane launcher is `bash scripts/ci/devsy-dagger.sh probe` or `build`.
It adapts the bundle transfer, private resources and engine lock from homebrew-tools
at c075a1fc82413c071e87becdb051a64bfbe508fe. It requires a clean source checkpoint,
uploads only Git/source snapshots, and never starts a local engine or transfers
OCI artifacts through Dakota. `OMARCHY_MACHINE` defaults to the owned Devsy
machine. Provisioning/SSH may use native Devsy when MCP returns `workspace source
is missing` or `no running container found`; MCP status still reports ownership.

The remote machine needs verified Dagger CLI v0.20.6 (matching dagger.json), Docker
and the Ubuntu host prerequisites in scripts/ci/prepare-ubuntu-runner.sh. Install
the CLI from its official release archive and verify its official checksums.
No Dagger Cloud token is required. No images are published by this pipeline.

Dagger's persistent engine is separate from homebrew-tools. On Harvester it has
two CPUs with matching affinity, 5 GiB RAM, 6 GiB including swap and 4096 PIDs.
The existing builder VM has four vCPUs, an enforced two-CPU host quota, and
8 GiB guest RAM; Harvester applies its configured scheduling overcommit policy.
The day-job workspace is separate and unchanged.
GitHub retains four engine CPUs, 12 GiB RAM and 14 GiB including swap. Harvester
engine state is under /var/lib/containers/omarchy-dagger on the retained 200 GiB disk. The
launcher holds one engine lock for the entire pipeline and requires 30 GiB
actually free. The module explicitly mounts a LOCKED Podman containers-storage
cache; an opaque shell invocation alone would not create layer caching.
GitHub has an independent ephemeral engine/cache, not this Harvester cache.

Probe mode proves nested rootful Podman run/build/overlay and records an immediate
repeat build. Build mode runs the same Dagger candidate-build function twice,
with different execution IDs to prevent Dagger result replay. Product source,
architecture, pins and build arguments remain unchanged. Podman's content-based
keys decide which image layers can be reused. Inspect real stage logs, compiler
output, timings, resources and receipts before claiming a speedup. The first
pass is not assumed to have an empty cache. A narrow source-change probe remains
separate; the worker does not alter product files to manufacture one.

`dagger-parity.yml` is the migration workflow. Probe/build use the module; accept
reuses a selected immutable OCI artifact through dagger-host-runtime.sh on the
Ubuntu host. That script preserves existing import/manifest/archive checks,
overlay fatal lint, boot screenshots and lifecycle gates. Existing workflows
retain their build/runtime backstops while also invoking Dagger source contracts.
Remove duplicate build paths only after equivalence and real acceptance pass.

Exports and failed-run logs remain in ~/omarchy-builds/run.* on Harvester.
CheckResult must pass after every evidence export; export success is not build
or VM success. Retrieve only explicitly needed small receipts. Before safe Devsy
stop, verify no worker/transfer is active. Preserve the VM disk, named shell builds
volume and Dagger/Podman cache. Never force-stop a shared machine or prune another
run. KVM device presence is not boot acceptance; retain actual guest evidence.

## Verified compact-builder checkpoint (2026-11-19)

On source d4f442777625a52e8158e836bb4156bb245cd20b, the existing
omarchy-ac-0b534 VM was Running/Ready at 4 vCPU / 8 GiB / 200 GiB with an
enforced two-CPU host quota. homebrew-t-18140 stayed stopped and the day-job
devsy-shared-harvester-4f954 VM was unchanged. No pods were unschedulable.

The real Dagger v0.20.6 constructor, rootful nested Podman run, overlay build,
repeat build and CheckResult passed. The tiny two-instruction build took
0.36 seconds initially and 0.04 seconds on repeat; the second log records
`Using cache` with the same image ID. This is not an Omarchy-image cold/warm
benchmark, image qualification, or graphical/KVM acceptance.

The nested worker inherits the engine's enforced cgroups because it has no
delegated pids controller; it does not change host Podman or firewall policy.
The source tests cover oversized engine rejection, insufficient guest headroom,
and preserving independent probe failures while failing qualification.

Evidence remains on the builder under
`/home/kdlocpanda/omarchy-builds/run.RzDls6Yw` (3.2 MiB at probe completion).
The persistent engine cache remains `/var/lib/containers/omarchy-dagger`
(2.9 GiB at probe completion), with 185 GiB disk space free. Failed attempts
are retained in sibling run directories; no local OCI artifact was downloaded.
