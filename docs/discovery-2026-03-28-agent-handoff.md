# Agent Handoff: 2026-03-28

## Goal the user set

Finish `omarchy-bootc` enough that:

- it produces a working bootable VM artifact at minimum, and
- it moves toward the user's long-term goal of switching from a Bluefin/Fedora host to an Arch/Omarchy-style image.

The user explicitly wants this to track Jorge Castro / Bluefin / bootc ideas where possible, but not become a Fedora/Dakota clone.

## High-level repo state

- Repo: `joshyorko/omarchy-bootc`
- Local branch: `main`
- Local status when I stopped:
  - modified: `build/10-base.sh`
  - modified: `scripts/ci/vm-smoke.sh`
- Last known `main` head from local git/GitHub checks: `44c3535`

## What I learned from GitHub / CI

I used `gh` before the permission mode flipped back to restricted.

### Open / recent PR state

- Open PR:
  - `#12` draft, title: `Integrate real bootc-on-Arch flow and native install-to-disk outputs`
  - status was `MERGEABLE` but `UNSTABLE`
  - last updated: `2026-03-23`
- Recently merged PRs were all from `2026-03-22` to `2026-03-23`
- There has effectively been no fresh PR activity since then

### Current failure on `main`

The recurring scheduled `Build and optionally publish bootc image` workflow on `main` was failing daily.

Latest failure I inspected:

- Run: `23683086344`
- URL: `https://github.com/joshyorko/omarchy-bootc/actions/runs/23683086344`

Important detail:

- The image build itself now succeeds.
- The failure is in the VM artifact path, specifically `VM smoke test (headless qemu + ssh)`.
- The actual failure occurs earlier inside `bootc-image-builder` while generating the qcow2 manifest.

Critical log snippet from the failed run:

`bootc-image-builder` ends with:

- `failed to run lsinitrd --mod --kver 6.19.9-arch1-1`
- `No <initramfs file> specified and the default image '' cannot be accessed!`

Meaning:

- the Arch image has an initramfs,
- but not at a kernel-version-addressable path that `lsinitrd -k <kver>` can resolve.

## What I verified locally

I built the local image successfully with:

- `just build`

The build completes locally and produces `localhost/omarchy-bootc:stable`.

I then inspected the built image with `podman run`.

### Important filesystem facts from the built image

Observed in the image:

- `/boot/initramfs-linux.img`
- `/boot/vmlinuz-linux`
- `/usr/lib/modules/6.19.9-arch1-1/`

But this command failed inside the image:

- `lsinitrd -k 6.19.9-arch1-1`

That reproduces the CI symptom directly.

### Key discovery

I tested two possible compatibility fixes inside throwaway containers:

1. symlink `/usr/lib/modules/6.19.9-arch1-1/initramfs.img -> /boot/initramfs-linux.img`
2. symlink `/boot/initramfs-6.19.9-arch1-1.img -> /boot/initramfs-linux.img`

Result:

- either of those makes `lsinitrd -k 6.19.9-arch1-1` succeed

So the current blocker is not "no initramfs". It is "Arch naming does not match what `bootc-image-builder` expects when it resolves by kernel version."

## Local code changes I made

### 1. `build/10-base.sh`

I added a compatibility block after base package install and before user creation.

Purpose:

- discover the latest kernel version under `/usr/lib/modules`
- create:
  - `/boot/initramfs-${kver}.img -> initramfs-linux.img`
  - `/boot/vmlinuz-${kver} -> vmlinuz-linux`
  - `/usr/lib/modules/${kver}/initramfs.img -> ../../../boot/initramfs-linux.img`

Reason:

- this gives `bootc-image-builder` / `lsinitrd -k` the versioned initramfs lookup it expects
- without changing Arch's native preset naming

### 2. `scripts/ci/vm-smoke.sh`

I fixed an existing shellcheck warning:

- changed `hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22`
- to `hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22`

Reason:

- shellcheck in this repo treats warnings as failures in practice
- this was existing lint debt that would block a PR even if the image fix worked

### 3. Shellcheck status

After the above edit, this passed locally:

- `shellcheck build/10-base.sh build/20-omarchy.sh build/30-services.sh scripts/ci/vm-smoke.sh`

## Build status when interrupted

After patching, I started another `just build`.

What was confirmed before interruption:

- the build re-entered `build/10-base.sh`
- the new symlink logic executed correctly
- logs showed the symlinks being created exactly as intended

I did **not** finish the full post-patch end-to-end verification because the turn was interrupted.

Specifically, I did **not** get to complete:

- final `just build` completion check after the patch
- `just build-qcow2`
- `just run-vm`

## What the next agent should do first

1. Re-run:
   - `just build`
2. If successful, verify inside the built image:
   - `ls -l /boot/initramfs-*`
   - `ls -l /usr/lib/modules/*/initramfs.img`
   - `lsinitrd -k <kver>`
3. Then run:
   - `just build-qcow2`
4. If qcow2 succeeds, run:
   - `just run-vm`
   - or at minimum inspect the produced artifact under `output/`

The highest-value checkpoint is whether `bootc-image-builder` now gets past manifest generation.

## If the qcow2 path still fails

Likely next places to inspect:

- `scripts/ci/vm-smoke.sh`
- `image/disk.toml`
- whether `bootc-image-builder` also expects a versioned kernel path beyond the initramfs path
- whether Arch needs stronger alignment with bootcrew's initramfs/rootfs prep

Possible follow-up fixes if the simple symlink approach is insufficient:

- add a dracut config that emits a versioned initramfs path directly
- rebuild initramfs explicitly the way bootcrew does
- move from the current "bootc-image-builder from outside the image" model toward real bootc-in-image generation

## What I learned from bootcrew references

I fetched these upstream reference files:

- `https://raw.githubusercontent.com/bootcrew/mono/main/shared/initramfs.sh`
- `https://raw.githubusercontent.com/bootcrew/mono/main/arch/Containerfile`
- `https://raw.githubusercontent.com/bootcrew/arch-bootc/main/Containerfile`

Important takeaways:

- bootcrew's real Arch bootc images:
  - build/install `bootc` inside the image
  - add dracut drop-ins for `bootc` / `ostree`
  - run `dracut --force .../initramfs.img`
  - prepare the rootfs for image-based semantics, not just pacman DB relocation
- this repo currently does **not** do that full prep
- this repo is still using a weaker compatibility approach:
  - Arch image + `bootc-image-builder` container outside the image
  - minimal pacman DB relocation
  - no true `bootc install` path inside the Arch image

## What this means for the user's "switch from Bluefin to Arch image" idea

Short version:

- Getting qcow2 booting in a VM is realistic right now.
- A true cross-distro `bootc switch` / rebase path from Bluefin into this Arch image is **not** done yet.

Why:

- the repo does not yet ship `bootc` in the image
- it does not yet fully prepare the rootfs the way real bootc/ostree images do
- it therefore cannot yet be treated as a real rebase target the way Bluefin/Universal Blue images are

## What to preserve from Jorge / Bluefin thinking

The user's long-term direction is still coherent:

- image-owned system content should live in the immutable side of the OS
- mutable machine/user state should survive image changes
- switching images should preserve `/var` and managed config/state rather than reinstalling everything manually

For this repo, the practical interpretation is:

- first get the VM image path green
- then introduce real bootc-in-image support
- then document how `/etc`, `/var`, and user homes should be treated for rebase/switch scenarios

Do **not** jump straight to BuildStream/Dakota here unless the user explicitly pivots the project. The repo and the user's earlier note both point toward "Arch semantics first, bootc delivery second."

## Suggested next documentation work

Once the VM path is verified, add docs covering:

- current state preservation assumptions:
  - `/usr` image-owned
  - `/var` mutable
  - user homes under `/var/home` if/when true bootc prep is adopted
- why Bluefin-style switching is still blocked today
- what milestone unlocks it:
  - bootc binary in image
  - dracut/bootc module integration
  - bootc rootfs prep closer to bootcrew

## Files most relevant for the next step

- `build/10-base.sh`
- `scripts/ci/vm-smoke.sh`
- `Containerfile`
- `image/disk.toml`
- `docs/bootcrew-comparison.md`
- `docs/technical-status.md`
- `.github/workflows/build.yml`
