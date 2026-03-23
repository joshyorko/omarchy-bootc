###############################################################################
# omarchy-bootc
###############################################################################
# Arch-based bootc proof-of-concept image for Omarchy-compatible immutable
# desktops.
#
# IMPORTANT STATUS NOTES
# - This Containerfile targets a technical POC, not production parity.
# - bootc is built from upstream source (BOOTC_REF) during the image build.
# - pacman/sysroot relocation to /usr/lib/sysimage follows bootc/ostree patterns
#   and should be validated against real upgrade/rebase flows.
# - qcow2 output is generated via bootc install-to-disk; bootc-image-builder
#   remains as a fallback helper.
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

ARG BOOTC_REF="v1.13.0"
ENV BOOTC_REF=${BOOTC_REF}

# ── Pacman keyring + full system update ───────────────────────────────────────
# Layer is separate so the package cache can be shared across rebuilds.
RUN --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Syu --noconfirm

# ── Relocate pacman-managed /var content into /usr/lib/sysimage ───────────────
# Align with bootcrew/arch-bootc to keep /var mutable and /usr image-owned.
RUN grep "= */var" /etc/pacman.conf | sed "/= *\\/var/s/.*=// ; s/ //" | \
        xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed \"s@/var/@@\"))\" && mv -v \"$1\" \"/usr/lib/sysimage/$(echo \"$1\" | sed \"s@/var/@@\")\"' '' && \
    sed -i -e "/= *\\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

# ── Keep full locales/help available and refresh glibc after relocation ───────
RUN sed -i 's/^[[:space:]]*NoExtract/#&/' /etc/pacman.conf
RUN --mount=type=tmpfs,dst=/tmp \
    --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman/pkg,sharing=locked \
    pacman -Sy glibc --noconfirm

# ── Build-time OS customisation — numbered scripts run in order ───────────────
# 10-base.sh    core system packages (bootc, networking, containers)
# 20-omarchy.sh minimal Wayland/Hyprland session baseline for POC credibility
# 30-services.sh enable / disable systemd services
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/10-base.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/20-omarchy.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/30-services.sh

# ── bootc metadata + lint ─────────────────────────────────────────────────────
LABEL containers.bootc=1
RUN bootc container lint
