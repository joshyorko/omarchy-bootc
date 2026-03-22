# build/

Build scripts are numbered and executed in order during `podman build`.

| Script | Purpose |
|---|---|
| `10-base.sh` | Install core system packages (bootc, networking, containers) using **pacman** |
| `20-omarchy.sh` | Install Hyprland and Omarchy-specific packages — **placeholder, see below** |
| `30-services.sh` | Enable / disable systemd services |

All scripts follow the `set -eoux pipefail` convention and emit
`::group::`/`::endgroup::` markers compatible with GitHub Actions log folding.

## Adding packages

Packages are declared in `custom/packages/` — not hard-coded in the scripts —
so they can be audited and diffed easily:

* `custom/packages/base.packages` — one package name per line; installed in `10-base.sh`
* `custom/packages/omarchy.packages` — Hyprland / Omarchy packages; installed in `20-omarchy.sh`

Lines starting with `#` and blank lines are ignored.

## Adding a new build script

Create a new numbered script, e.g. `build/40-fonts.sh`:

```bash
#!/usr/bin/bash
set -eoux pipefail
pacman -S --noconfirm --needed ttf-nerd-fonts-symbols
echo "Fonts installed."
```

Then add a corresponding `RUN` directive to the `Containerfile`:

```dockerfile
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/40-fonts.sh
```

## Note on package manager

This image uses **pacman**, not dnf5, rpm-ostree, or any Fedora tooling.
The pacman database is relocated to `/usr/lib/sysimage/pacman` for
ostree / bootc immutable-root compatibility (see `Containerfile` for details).
