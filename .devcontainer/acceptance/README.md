# Harvester acceptance worker

Remote-only profile for a dedicated `omarchy-acceptance` Devsy workspace. The
pattern follows homebrew-tools at c075a1fc82413c071e87becdb051a64bfbe508fe:
a private worker, persistent named storage, effective resource checks and a
single cache lock. It does not use or share homebrew-tools' Dagger engine.

Provision with the configured Harvester provider at 6 vCPU, 16 GiB RAM and
200 GiB disk; select this profile with `--devcontainer id:acceptance`.
The container budget is 4 CPU, 12 GiB RAM, 14 GiB RAM plus swap and 4096 PIDs.
The privileged container is confined to the dedicated builder VM. Never use
this profile on Dakota or mount Dakota's Docker socket into it.

Use Devsy MCP for workspace status/exec when available. Native fallback:

```sh
devsy workspace ssh omarchy-acceptance --command 'uname -a'
```

Inside that remote container, create a clean checkout of the exact PR commit
under `/builds`, verify its full SHA, then run:

```sh
OMARCHY_REMOTE_BUILDER=harvester timeout --kill-after=60s 6h bash scripts/ci/harvester-cache-proof.sh
```

Keep the command's stdout/stderr in a remote log. The worker prints its retained
`/builds/omarchy-bootc/run.<sha>.*` evidence directory. It serializes all builds
through `engine.lock`, checks 30 GiB genuinely free before each phase and uses
Podman's persistent overlay image store at `/builds/containers`. No automatic
prune, cache deletion or artifact transfer to Dakota is performed.

The cold/warm labels denote consecutive passes, not a guarantee the first cache
is empty. Both use identical clean source, architecture, pins, toolchain and
build arguments. Podman's content-based layer keys decide reuse; source SHA and
image/archive/manifest identity are recorded separately. Read stage logs and
`*-cache-lines.txt`, compiler output, `timings.tsv`, `*.resources` and cgroup
receipts before claiming speedup. Exports remain remote. Each pass imports and
verifies its exact candidate archive. Warm cache does not replace signed package,
fatal lint, bootc, GUI screenshot or rollback gates. A narrow source-change cache
probe is a separate measurement; this worker does not modify product source to
manufacture one.

KVM availability is recorded. Without accessible KVM, retain the build proof and
leave graphical VM acceptance on GitHub. The repository's Dagger module currently
builds installer ISO work; it is not the cache engine for this Podman image path.
Do not build installer ISO artifacts until their accepted-image prerequisite.

Retrieve only explicitly needed small receipts. Before stopping the workspace,
verify the worker has exited and no owned run is active; use native Devsy stop
protection, never force-stop a shared machine. Stopping preserves disk/cache.
Failed runs remain for diagnosis. Do not delete another run or its cache.
