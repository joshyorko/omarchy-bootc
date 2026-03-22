###############################################################################
# omarchy-bootc
###############################################################################
# An Arch-based bootc proof-of-concept image for Omarchy-compatible immutable
# desktops.  Inspired by the @projectbluefin/finpilot repository structure but
# built entirely on Arch Linux — no Fedora, Bluefin, Silverblue, CentOS,
# GNOME OS, or dnf5 assumed.
#
# Build layers
#   ctx         — injects local build/ custom/ systemd/ trees into the build
#   main        — starts from archlinux:base, configures for bootc, installs
#                 packages, enables services, then lints the result
###############################################################################

# ── Context stage ─────────────────────────────────────────────────────────────
# Makes local files available to the main stage via --mount=type=bind,from=ctx.
# Nothing is copied into the final image from this stage directly.
FROM scratch AS ctx

COPY build   /build
COPY custom  /custom
COPY systemd /systemd

# ── Main image ────────────────────────────────────────────────────────────────
# Arch Linux base.  Replace with a pinned digest for reproducible builds.
# Example: FROM archlinux:base@sha256:<digest>
FROM archlinux:base

# ── Pacman keyring + full system update ───────────────────────────────────────
# Layer is separate so the package cache can be shared across rebuilds.
RUN --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Syu --noconfirm

# ── Relocate pacman DB for ostree / bootc immutable-root compatibility ────────
# ostree / bootc treat /var as ephemeral user-data that is NOT part of the
# deployed image.  Moving the pacman DB into /usr/lib/sysimage/pacman keeps
# package metadata in the read-only /usr layer so it survives upgrades.
RUN mkdir -p /usr/lib/sysimage && \
    cp -a /var/lib/pacman /usr/lib/sysimage/pacman && \
    rm -rf /var/lib/pacman && \
    ln -s /usr/lib/sysimage/pacman /var/lib/pacman && \
    sed -i 's|^#\?DBPath\s*=.*|DBPath      = /usr/lib/sysimage/pacman|' \
        /etc/pacman.conf

# ── Build-time OS customisation — numbered scripts run in order ───────────────
# 10-base.sh    core system packages (bootc, networking, containers)
# 20-omarchy.sh Hyprland + Omarchy-specific packages  (placeholders)
# 30-services.sh enable / disable systemd services

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/10-base.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/20-omarchy.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/30-services.sh

# ── Verify bootc compatibility ────────────────────────────────────────────────
RUN bootc container lint
