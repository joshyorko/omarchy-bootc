###############################################################################
# Omarchy Quattro on Bootcrew's Arch bootc construction
###############################################################################

ARG ARCH_BOOTSTRAP_REF="docker.io/archlinux/archlinux:latest@sha256:0de35fe2ee793494ccfc99b202f6b30215b078baf2b082e9ccb027840c534fc1"
ARG BOOTCREW_MONO_REVISION="5f048fa65a94daefc814d3cdd941d8d1e113c09e"
ARG BOOTC_REVISION="3e76c16556c55e6d15d31bd47602b231e2131cb2"

# Current Arch is only a disposable pacstrap tool. No package from this image
# is copied into the final root.
FROM ${ARCH_BOOTSTRAP_REF} AS stable-bootstrap
COPY build/configure-quattro-repositories.sh /bootstrap/configure-quattro-repositories.sh
COPY custom/pacman/quattro-repositories.conf /bootstrap/quattro-repositories.conf
RUN cp /etc/pacman.conf /tmp/stable-pacman.conf && \
    bash /bootstrap/configure-quattro-repositories.sh \
        /tmp/stable-pacman.conf \
        /bootstrap/quattro-repositories.conf && \
    sed -i '/^[[:space:]]*NoExtract[[:space:]]*=/d' /tmp/stable-pacman.conf && \
    cp /tmp/stable-pacman.conf /tmp/stable-pacman-bootstrap.conf && \
    install -d -m 0755 /bootstrap/no-hooks && \
    for hook in /usr/share/libalpm/hooks/*.hook; do \
        hook_name="$(basename "${hook}")"; \
        printf '%s\n' \
            '[Trigger]' \
            'Operation = Install' \
            'Type = Package' \
            'Target = __omarchy_stable_bootstrap_never_matches__' \
            '' \
            '[Action]' \
            'Description = bootstrap root without chroot runtime hooks' \
            'When = PostTransaction' \
            'Exec = /usr/bin/true' \
            >"/bootstrap/no-hooks/${hook_name}"; \
    done && \
    sed -i '/^\[options\]$/a HookDir = /bootstrap/no-hooks' \
        /tmp/stable-pacman-bootstrap.conf
RUN --mount=type=cache,dst=/var/cache/pacman/pkg,sharing=locked \
    install -d -m 0755 \
        /stable-root/var/lib/pacman \
        /stable-root/var/log && \
    pacman \
        --config /tmp/stable-pacman-bootstrap.conf \
        --root /stable-root \
        --dbpath /stable-root/var/lib/pacman \
        --cachedir /var/cache/pacman/pkg \
        --gpgdir /etc/pacman.d/gnupg \
        --logfile /stable-root/var/log/pacman.log \
        --disable-sandbox \
        --noconfirm \
        -Sy base pacman-mirrorlist && \
    install -D -m 0644 \
        /tmp/stable-pacman.conf \
        /stable-root/etc/pacman.conf

# The final Arch root begins empty and is populated only by Omarchy stable.
FROM scratch AS stable-base
COPY --from=stable-bootstrap /stable-root /
RUN systemd-sysusers && \
    update-ca-trust && \
    pacman-key --init && \
    pacman-key --populate archlinux

FROM scratch AS bootcrew-ctx
COPY vendor/bootcrew /

FROM stable-base AS bootc-builder
ARG BOOTC_REVISION
RUN pacman -Syu --noconfirm make git rust go-md2man ostree glibc pkgconf
WORKDIR /home/build
RUN --mount=type=bind,from=bootcrew-ctx,source=/,target=/ctx \
    test "$(cat /ctx/BOOTC_REVISION)" = "${BOOTC_REVISION}" && \
    BOOTC_SOURCE="$(cat /ctx/BOOTC_SOURCE)" \
    BOOTC_REVISION="${BOOTC_REVISION}" \
    bash /ctx/shared/build.sh

FROM stable-base AS bootcrew-system
ARG BOOTCREW_MONO_REVISION
ARG BOOTC_REVISION
COPY --from=bootc-builder /output /

# Bootcrew mono arch/Containerfile at BOOTCREW_MONO_REVISION, applied to the
# empty-root Omarchy stable package universe.
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

RUN pacman -Syu --noconfirm

RUN pacman -Sy --noconfirm \
        base bubblewrap dracut linux linux-firmware ostree btrfs-progs \
        e2fsprogs xfsprogs dosfstools skopeo dbus dbus-glib glib2 \
        shadow openssh && \
    pacman -S --clean --noconfirm

RUN systemctl enable systemd-networkd systemd-resolved systemd-timesyncd sshd && \
    systemctl mask systemd-firstboot.service

RUN echo "uninitialized" > /etc/machine-id && \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime

RUN printf '[Match]\nType=ether\n\n[Network]\nDHCP=yes\n' \
    > /usr/lib/systemd/network/20-wired.network

RUN printf 'L! /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf\n' \
    > /usr/lib/tmpfiles.d/resolv-conf.conf

RUN --mount=type=tmpfs,dst=/tmp \
    --mount=type=tmpfs,dst=/root \
    --mount=type=bind,from=bootcrew-ctx,source=/,target=/ctx \
    bash /ctx/shared/initramfs.sh

RUN --mount=type=bind,from=bootcrew-ctx,source=/,target=/ctx \
    sed -i 's|^HOME=.*|HOME=/var/home|' /etc/default/useradd && \
    bash /ctx/shared/bootc-rootfs.sh

RUN find /run -mindepth 1 -maxdepth 1 \
        ! -name .containerenv \
        ! -name host \
        -exec rm -rf -- {} + && \
    find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

RUN --mount=type=bind,from=bootcrew-ctx,source=/,target=/ctx \
    test "$(cat /ctx/REVISION)" = "${BOOTCREW_MONO_REVISION}" && \
    test "$(cat /ctx/BOOTC_REVISION)" = "${BOOTC_REVISION}" && \
    install -D -m 0644 /ctx/SOURCE \
        /usr/share/omarchy-bootc/sources/bootcrew-mono.source && \
    install -D -m 0644 /ctx/REVISION \
        /usr/share/omarchy-bootc/sources/bootcrew-mono.revision && \
    install -D -m 0644 /ctx/BOOTC_SOURCE \
        /usr/share/omarchy-bootc/sources/bootc.source && \
    install -D -m 0644 /ctx/BOOTC_REVISION \
        /usr/share/omarchy-bootc/sources/bootc.revision && \
    install -d -m 0755 /usr/share/omarchy-bootc && \
    pacman -Q > /usr/share/omarchy-bootc/bootcrew-stable-package-manifest.txt && \
    test -z "$(pacman -Qu)"

LABEL org.opencontainers.image.bootcrew.revision="${BOOTCREW_MONO_REVISION}"
LABEL org.opencontainers.image.bootc.revision="${BOOTC_REVISION}"
LABEL containers.bootc=1
RUN bootc container lint --fatal-warnings

FROM scratch AS install-ctx
COPY build/20-quattro.sh /build/20-quattro.sh
COPY build/configure-quattro-repositories.sh /build/configure-quattro-repositories.sh
COPY build/lib /build/lib
COPY build/bootc-disabled-hooks.txt /build/bootc-disabled-hooks.txt
COPY custom/pacman /custom/pacman

FROM scratch AS provenance-ctx
COPY build/verify-quattro-payload.sh /build/verify-quattro-payload.sh

FROM scratch AS boot-ownership-ctx
COPY build/30-bootc-ownership.sh /build/30-bootc-ownership.sh
COPY build/bootc-disabled-hooks.txt /build/bootc-disabled-hooks.txt

FROM scratch AS acceptance-ctx
COPY build/25-quattro-user.sh /build/25-quattro-user.sh
COPY build/acceptance-firstboot.sh /build/acceptance-firstboot.sh
COPY build/acceptance-firstboot.service /build/acceptance-firstboot.service
COPY build/stage-acceptance-node.sh /build/stage-acceptance-node.sh

FROM scratch AS final-ctx
COPY build/verify-publishable-image.sh /build/verify-publishable-image.sh

FROM bootcrew-system AS quattro-base

RUN --mount=type=bind,from=install-ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman/pkg,sharing=locked \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/20-quattro.sh

RUN --mount=type=bind,from=provenance-ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/verify-quattro-payload.sh

RUN --mount=type=bind,from=boot-ownership-ctx,source=/,target=/ctx \
    bash /ctx/build/30-bootc-ownership.sh

LABEL containers.bootc=1
RUN bootc container lint --fatal-warnings

FROM quattro-base AS acceptance
RUN --mount=type=bind,from=acceptance-ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/stage-acceptance-node.sh && \
    bash /ctx/build/25-quattro-user.sh
RUN bootc container lint --fatal-warnings

FROM quattro-base AS final
RUN --mount=type=bind,from=final-ctx,source=/,target=/ctx \
    bash /ctx/build/verify-publishable-image.sh

LABEL containers.bootc=1
RUN bootc container lint --fatal-warnings
