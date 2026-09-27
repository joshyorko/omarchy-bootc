###############################################################################
# Omarchy Quattro on Bootcrew's Arch bootc construction
###############################################################################

ARG ARCH_BOOTSTRAP_REF="docker.io/archlinux/archlinux:latest@sha256:0de35fe2ee793494ccfc99b202f6b30215b078baf2b082e9ccb027840c534fc1"
ARG BOOTCREW_MONO_REVISION="5f048fa65a94daefc814d3cdd941d8d1e113c09e"
ARG BOOTC_REVISION="fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60"
ARG BOOTC_VERSION="v1.16.13"
ARG SELINUX_USERSPACE_VERSION="3.11"
ARG SELINUX_LIBSEPOL_SHA256="79f3d2c88f44b7eb5cf54d9792e03232297e17f97a179163f2750099a00f164d"
ARG SELINUX_LIBSELINUX_SHA256="73d419c6e20e874adaa4019372cbd097eecf4d276e13f27ec5e67d35c0bd203c"
ARG COREUTILS_VERSION="9.11"
ARG COREUTILS_SHA256="394024eda0a5955217ceda9cd1201e65dc8fa3aa29c2951135a49521d57c3cc3"
ARG COREUTILS_SOURCE_URL="https://github.com/coreutils/coreutils/releases/download/v9.11/coreutils-9.11.tar.xz"
ARG OMARCHY_QUATTRO_REVISION="c668141e9c42b13c80c9ca4ea108e11708c5e8a5"
ARG OMARCHY_VERSION="4.0.4-1"


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
ARG BOOTC_VERSION
ARG SELINUX_USERSPACE_VERSION
ARG SELINUX_LIBSEPOL_SHA256
ARG SELINUX_LIBSELINUX_SHA256
ARG COREUTILS_VERSION
ARG COREUTILS_SHA256
ARG COREUTILS_SOURCE_URL
RUN pacman -Syu --noconfirm curl flex clang gcc gperf python make git diffutils inetutils rust go-md2man ostree glibc pkgconf pcre2 && \
    workdir="$(mktemp -d)" && \
    curl --fail --location --retry 3 --retry-delay 2 \
        "https://github.com/SELinuxProject/selinux/releases/download/${SELINUX_USERSPACE_VERSION}/libsepol-${SELINUX_USERSPACE_VERSION}.tar.gz" \
        --output "${workdir}/libsepol.tar.gz" && \
    curl --fail --location --retry 3 --retry-delay 2 \
        "https://github.com/SELinuxProject/selinux/releases/download/${SELINUX_USERSPACE_VERSION}/libselinux-${SELINUX_USERSPACE_VERSION}.tar.gz" \
        --output "${workdir}/libselinux.tar.gz" && \
    printf '%s  %s\n' "${SELINUX_LIBSEPOL_SHA256}" "${workdir}/libsepol.tar.gz" | sha256sum -c - && \
    printf '%s  %s\n' "${SELINUX_LIBSELINUX_SHA256}" "${workdir}/libselinux.tar.gz" | sha256sum -c - && \
    tar -xzf "${workdir}/libsepol.tar.gz" -C "${workdir}" && \
    tar -xzf "${workdir}/libselinux.tar.gz" -C "${workdir}" && \
    make -C "${workdir}/libsepol-${SELINUX_USERSPACE_VERSION}" -j"$(nproc)" && \
    make -C "${workdir}/libsepol-${SELINUX_USERSPACE_VERSION}" DESTDIR=/ SHLIBDIR=/usr/lib install && \
    make -C "${workdir}/libselinux-${SELINUX_USERSPACE_VERSION}" DISABLE_RPM=y USE_PCRE2=y -j"$(nproc)" && \
    make -C "${workdir}/libselinux-${SELINUX_USERSPACE_VERSION}" DISABLE_RPM=y USE_PCRE2=y DESTDIR=/ SBINDIR=/usr/bin SHLIBDIR=/usr/lib install && \
    ldconfig && \
    curl --fail --location --retry 5 --retry-delay 2 --connect-timeout 30 --max-time 300 \
        "${COREUTILS_SOURCE_URL}" \
        --output "${workdir}/coreutils.tar.xz" && \
    printf '%s  %s\n' "${COREUTILS_SHA256}" "${workdir}/coreutils.tar.xz" | sha256sum -c - && \
    tar -xJf "${workdir}/coreutils.tar.xz" -C "${workdir}" && \
    sed -i '1i#include <wchar.h>' \
        "${workdir}/coreutils-${COREUTILS_VERSION}/lib/mcel.h" && \
    cd "${workdir}/coreutils-${COREUTILS_VERSION}" && \
    FORCE_UNSAFE_CONFIGURE=1 CC=gcc ./configure --prefix=/usr --libexecdir=/usr/lib --with-selinux --disable-nls && \
    make CC=gcc CPPFLAGS="-include ${workdir}/coreutils-${COREUTILS_VERSION}/lib/arg-nonnull.h" -j"$(nproc)" \
        $(grep -E '^lib/[^: ]+\.h:' Makefile | sed -E 's/^([^:]+).*/\1/' | sort -u) src/version.h && \
    make CC=gcc CPPFLAGS="-include ${workdir}/coreutils-${COREUTILS_VERSION}/lib/arg-nonnull.h" \
        -j"$(nproc)" src/chcon && \
    install -D -m 0755 src/chcon /output/usr/bin/chcon && \
    rm -rf "${workdir}"
WORKDIR /home/build
RUN --mount=type=bind,from=bootcrew-ctx,source=/,target=/ctx \
    test "$(cat /ctx/BOOTC_REVISION)" = "${BOOTC_REVISION}" && \
    test "$(cat /ctx/BOOTC_VERSION)" = "v1.16.13" && \
    BOOTC_SOURCE="$(cat /ctx/BOOTC_SOURCE)" \
    BOOTC_REVISION="${BOOTC_REVISION}" \
    bash /ctx/shared/build.sh && \
    install -D -m 0755 /usr/lib/libselinux.so.1 /output/usr/lib/libselinux.so.1 && \
    install -D -m 0755 /usr/lib/libsepol.so.2 /output/usr/lib/libsepol.so.2

FROM stable-base AS bootcrew-system
ARG OMARCHY_QUATTRO_REVISION
ARG OMARCHY_VERSION
ENV OMARCHY_QUATTRO_REVISION="${OMARCHY_QUATTRO_REVISION}" \
    OMARCHY_VERSION="${OMARCHY_VERSION}"

ARG BOOTCREW_MONO_REVISION
ARG BOOTC_REVISION
ARG BOOTC_VERSION
ARG SELINUX_USERSPACE_VERSION
ARG COREUTILS_VERSION
COPY --from=bootc-builder /output /

# Bootcrew mono arch/Containerfile at BOOTCREW_MONO_REVISION, applied to the
# empty-root Omarchy stable package universe.
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

RUN pacman -Syu --noconfirm

RUN pacman -Sy --noconfirm \
        base bubblewrap dracut linux linux-firmware ostree btrfs-progs \
        e2fsprogs xfsprogs dosfstools skopeo dbus dbus-glib glib2 \
        shadow openssh pcre2 podman && \
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
    install -D -m 0644 /ctx/BOOTC_VERSION \
        /usr/share/omarchy-bootc/sources/bootc-version && \
    install -d -m 0755 /usr/share/omarchy-bootc && \
    pacman -Q > /usr/share/omarchy-bootc/bootcrew-stable-package-manifest.txt && \
    pacman -Qi > /usr/share/omarchy-bootc/bootcrew-stable-package-provenance.txt && \
    find /var/lib/pacman/sync -maxdepth 1 -type f -name '*.db*' -print0 | sort -z | \
        xargs -0 -r sha256sum > /usr/share/omarchy-bootc/bootcrew-repository-database-sha256sums.txt && \
    test -z "$(pacman -Qu)"

LABEL org.opencontainers.image.bootcrew.revision="${BOOTCREW_MONO_REVISION}"
LABEL org.opencontainers.image.bootc.revision="${BOOTC_REVISION}"
LABEL org.opencontainers.image.bootc.version="${BOOTC_VERSION}"
LABEL org.opencontainers.image.selinux.userspace.version="${SELINUX_USERSPACE_VERSION}"
LABEL org.opencontainers.image.coreutils.version="${COREUTILS_VERSION}"
LABEL containers.bootc=1
RUN bootc container lint --fatal-warnings

FROM scratch AS install-ctx
COPY build/20-quattro.sh /build/20-quattro.sh
COPY build/cups-browsed.sysusers.conf /build/cups-browsed.sysusers.conf
COPY sources /sources

COPY build/configure-quattro-repositories.sh /build/configure-quattro-repositories.sh
COPY build/lib /build/lib
COPY build/bootc-disabled-hooks.txt /build/bootc-disabled-hooks.txt
COPY custom/pacman /custom/pacman

FROM scratch AS provenance-ctx
COPY build/verify-quattro-payload.sh /build/verify-quattro-payload.sh

FROM scratch AS boot-ownership-ctx
COPY build/30-bootc-ownership.sh /build/30-bootc-ownership.sh
COPY build/bootc-disabled-hooks.txt /build/bootc-disabled-hooks.txt
COPY build/lib/bootc-initramfs.sh /build/lib/bootc-initramfs.sh

FROM scratch AS update-ctx
COPY build/install-bootc-update.sh /build/install-bootc-update.sh
COPY custom/bootc /custom/bootc

FROM scratch AS acceptance-ctx
COPY build/25-quattro-user.sh /build/25-quattro-user.sh
COPY build/acceptance-firstboot.sh /build/acceptance-firstboot.sh
COPY build/acceptance-firstboot.service /build/acceptance-firstboot.service
COPY build/stage-acceptance-node.sh /build/stage-acceptance-node.sh

FROM scratch AS final-ctx
COPY build/verify-publishable-image.sh /build/verify-publishable-image.sh

FROM scratch AS adoption-ctx
COPY custom/first-boot/omarchy-adopt-existing-user.sh /custom/first-boot/omarchy-adopt-existing-user.sh
COPY custom/first-boot/omarchy-adoption-rollback.sh /custom/first-boot/omarchy-adoption-rollback.sh
COPY systemd/system/omarchy-adopt-existing-user.service /systemd/system/omarchy-adopt-existing-user.service

FROM scratch AS transition-ctx
COPY transition/omarchy-transition.sh /transition/omarchy-transition.sh

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

RUN --mount=type=bind,from=adoption-ctx,source=/,target=/ctx \
    install -D -m 0755 \
        /ctx/custom/first-boot/omarchy-adopt-existing-user.sh \
        /usr/lib/omarchy/omarchy-adopt-existing-user.sh && \
    install -D -m 0644 \
        /ctx/systemd/system/omarchy-adopt-existing-user.service \
        /usr/lib/systemd/system/omarchy-adopt-existing-user.service && \
    install -D -m 0755 \
        /ctx/custom/first-boot/omarchy-adoption-rollback.sh \
        /usr/bin/omarchy-adoption-rollback && \
    install -d -m 0755 /etc/systemd/system/display-manager.service.d && \
    printf '%s\n' \
        '[Unit]' \
        'After=omarchy-adopt-existing-user.service' \
        'Requires=omarchy-adopt-existing-user.service' \
        > /etc/systemd/system/display-manager.service.d/10-omarchy-adoption.conf && \
    systemctl enable omarchy-adopt-existing-user.service

RUN --mount=type=bind,from=update-ctx,source=/,target=/ctx \
    bash /ctx/build/install-bootc-update.sh

RUN --mount=type=bind,from=transition-ctx,source=/,target=/ctx \
    install -D -m 0755 \
        /ctx/transition/omarchy-transition.sh /usr/bin/omarchy-transition

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
