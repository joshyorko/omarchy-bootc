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
