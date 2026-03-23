# bootc delivery on Arch (research note)

_Last updated: 2026-03-23_

## Current state

- bootc is intentionally omitted from the base package list because Arch repos in CI have not provided a resolvable package (`custom/packages/base.packages`).
- Container builds defer `bootc container lint` for the same reason (`Containerfile` notes).
- The image path relies on `bootc-image-builder` (CentOS container) to create qcow2 output; the Arch image itself does not yet include bootc.

## Candidate delivery options

1) **Official Arch package (none today)**
   - Maintainability: best once available; no custom packaging.
   - CI complexity: low; normal pacman install.
   - Reproducibility: good if pinned to repo snapshot/mirror.
   - Fit: ideal, but blocked until Arch ships bootc.

2) **Build from AUR PKGBUILD (bootc / bootc-git / bootc-git-composefs)**【3:0†source】【3:3†source】【3:5†source】
   - Maintainability: medium; need to track PKGBUILD updates and upstream deps.
   - CI complexity: medium/high; add base-devel, build-time deps, and caching to keep builds tolerable.
   - Reproducibility: moderate; PKGBUILD churn and VCS sources mean we must pin versions/digests.
   - Fit: plausible for this repo if we control the PKGBUILD revision and build artifacts.

3) **Consume third-party binary repo (e.g., Chaotic-AUR bootc)**【3:2†source】
   - Maintainability: low effort but external trust/supply-chain risk.
   - CI complexity: low; add repo entry + key.
   - Reproducibility: weaker; repo content may roll without notice.
   - Fit: acceptable only for quick experiments; not great for long-lived images.

4) **Vendored upstream binary (ship tarball in tree or fetch in build)**
   - Maintainability: low/medium; manual updates and dependency drift to manage.
   - CI complexity: medium; need checksum pinning and dependency installs.
   - Reproducibility: good if checksums are pinned, but packaging hygiene must be enforced.
   - Fit: workable stopgap; bypasses pacman ownership and update flow unless wrapped as a package.

5) **Self-maintained pacman repo for bootc (recommended)**
   - Maintainability: medium; we own a PKGBUILD (possibly derived from AUR) and bump it when upstream releases.
   - CI complexity: medium; add a dedicated CI job to build bootc, sign artifacts, and publish to a small repo (GitHub Releases/pages/S3).
   - Reproducibility: strong; pin upstream source/version and publish signed packages with checksums.
   - Fit: best balance for this repo—keeps the main image build stable while providing a controlled bootc package once validated.

## Recommendation

- Prepare a self-maintained pacman repo path for bootc, built from a pinned PKGBUILD we track in-repo. Consume it via an opt-in pacman repo stanza only after the package is proven to build and pass minimal `bootc container lint` in CI.

## Do not do yet

- Do not add bootc to `custom/packages/base.packages` or enable `bootc container lint` in `Containerfile`.
- Do not switch the image build to a third-party binary repo by default.
- Do not add installer/BuildStream work in this spike.

## Smallest next step (safe experiment)

- Mirror a vetted PKGBUILD (start with `bootc` or `bootc-git` from AUR) into a scratch branch, run `makepkg` in CI to produce a signed package artifact, and publish it to a temporary repo directory. Do not wire the main image build to that repo yet; use the artifact only to validate bootc runs and `bootc container lint` in CI.
