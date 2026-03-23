# bootc delivery on Arch (research note)

_Last updated: 2026-03-23_

## Current state

- bootc is built from upstream source during the image build (pinned via `BOOTC_REF`, default `v1.13.0`), and `bootc container lint` now runs in the image build.
- Pacman/sysroot layout is shifted under `/usr/lib/sysimage`, composefs/ostree is enabled, and dracut is rebuilt with the bootc module.
- qcow2/raw output is produced via `bootc install --composefs-backend --via-loopback`; bootc-image-builder remains available as a fallback (`build-qcow2-bib`).

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

- Continue pinning upstream bootc via `BOOTC_REF`, keep `bootc container lint` green, and consider moving to a self-maintained pacman repo once the source build is stable in CI.

## Do not do yet

- Do not switch the image build to a third-party binary repo by default.
- Do not add installer/BuildStream work in this spike.
- Do not assume Arch will ship a bootc package soon; keep the pinned source build path maintained.

## Smallest next step (safe experiment)

- Add automated coverage for `bootc` upgrade/rebase/rollback on the composefs sysroot and evaluate whether a self-maintained pacman package would simplify long-term maintenance.
