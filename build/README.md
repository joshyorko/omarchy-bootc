# build/

Build scripts are numbered and executed in order during `podman build`.

| Script | Purpose |
|---|---|
| `10-base.sh` | Install core system packages (bootc, networking, containers) using **pacman** |
| `20-omarchy.sh` | Install a **minimal** Hyprland/Wayland baseline for technical POC credibility |
| `30-services.sh` | Enable/disable systemd services and first-boot unit |

All scripts use `set -eoux pipefail` and emit `::group::` / `::endgroup::`
markers for easier CI log folding.

## Package sources

Packages are declared in `custom/packages/` (not hard-coded in scripts):

- `custom/packages/base.packages`
- `custom/packages/omarchy.packages`

Lines starting with `#` and blank lines are ignored.

## Scope note

The `20-omarchy.sh` layer is intentionally constrained: it provides a small,
reviewable baseline rather than claiming full Omarchy parity.

## Adding a new build script

Create a new numbered script, e.g. `build/40-fonts.sh`:

```bash
#!/usr/bin/bash
set -eoux pipefail
pacman -S --noconfirm --needed ttf-nerd-fonts-symbols
echo "Fonts installed."
```

Then add a corresponding `RUN` directive to `Containerfile`:

```dockerfile
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/40-fonts.sh
```

## Note on package manager

This image uses **pacman**, not dnf5/rpm-ostree/Fedora toolchains.
