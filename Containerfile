###############################################################################
# omarchy-bootc
###############################################################################
# Arch-based bootc proof-of-concept image for Omarchy-compatible immutable
# desktops.
#
# IMPORTANT STATUS NOTES
# - This Containerfile targets a technical POC, not production parity.
# - bootc availability in Arch repositories is assumed here and must be
#   revalidated periodically.
# - pacman DB relocation for immutable /usr is based on known bootc/ostree
#   patterns but should still be validated against real upgrade flows.
# - bootc-image-builder compatibility is expected for qcow2 output, but only
#   runtime VM tests should be treated as proof.
###############################################################################

# ── Context stage ─────────────────────────────────────────────────────────────
# Makes local files available to the main stage via --mount=type=bind,from=ctx.
# Nothing is copied into the final image from this stage directly.
FROM scratch AS ctx

COPY build   /build
COPY custom  /custom
COPY systemd /systemd

# ── Main image ────────────────────────────────────────────────────────────────
# Arch Linux base. Replace with a pinned digest for reproducible builds.
# Example: FROM archlinux:base@sha256:<digest>
FROM archlinux:base

# ── Pacman keyring + full system update ───────────────────────────────────────
# Layer is separate so the package cache can be shared across rebuilds.
RUN --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Syu --noconfirm

# ── Relocate pacman DB for immutable-root expectations ────────────────────────
# bootc/ostree-style systems generally treat /var as mutable state and /usr as
# image-owned content. Moving pacman DB to /usr/lib/sysimage/pacman is an
# explicit compatibility assumption for this POC and should be tested during
# upgrade/rebase validation.
RUN mkdir -p /usr/lib/sysimage && \
    cp -a /var/lib/pacman /usr/lib/sysimage/pacman && \
    rm -rf /var/lib/pacman && \
    ln -s /usr/lib/sysimage/pacman /var/lib/pacman && \
    sed -i 's|^#\?DBPath\s*=.*|DBPath      = /usr/lib/sysimage/pacman|' \
        /etc/pacman.conf

# ── Build-time OS customisation — numbered scripts run in order ───────────────
# 10-base.sh    core system packages (bootc, networking, containers)
# 20-omarchy.sh minimal Wayland/Hyprland session baseline for POC credibility
# 30-services.sh enable / disable systemd services
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/10-base.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/20-omarchy.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/30-services.sh

# ── Verify bootc compatibility ────────────────────────────────────────────────
# This lint step catches common structural issues, but does not prove the image
# will boot in a VM.
RUN bootc container lint
