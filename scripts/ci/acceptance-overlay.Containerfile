ARG CANDIDATE_IMAGE
FROM ${CANDIDATE_IMAGE}

# This is a disposable runtime fixture layered on one already-built candidate.
# It must never be published as the normal Omarchy image.
COPY build/acceptance-firstboot.sh /ctx/build/acceptance-firstboot.sh
COPY build/acceptance-firstboot.service /ctx/build/acceptance-firstboot.service
COPY build/stage-acceptance-node.sh /ctx/build/stage-acceptance-node.sh
COPY build/25-quattro-user.sh /ctx/build/25-quattro-user.sh
# Refresh the verifier for guest-side protected reads; retain the parent OCI.
COPY build/acceptance-dependencies.sh /usr/lib/omarchy-bootc/acceptance-dependencies.sh

# Only this disposable layer permits the SSH harness through product UFW.
# Offline rule writing must not apply the rules to the build host's firewall.
# UFW releases its advisory lock but leaves the file; it is not image content.
RUN grep -Fxq ENABLED=yes /etc/ufw/ufw.conf && \
    sed -i 's/^ENABLED=yes$/ENABLED=no/' /etc/ufw/ufw.conf && \
    ufw allow 22/tcp comment 'disposable acceptance SSH' && \
    sed -i 's/^ENABLED=no$/ENABLED=yes/' /etc/ufw/ufw.conf && \
    rm -f /run/ufw.lock

RUN --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/stage-acceptance-node.sh && \
    bash /ctx/build/25-quattro-user.sh && \
    install -d -m 0755 /etc/sddm.conf.d /usr/lib/omarchy-acceptance && \
    printf '%s\n' \
        '[Autologin]' \
        'User=omarchy' \
        'Session=omarchy.desktop' \
        'Relogin=true' \
        > /usr/lib/omarchy-acceptance/autologin.conf && \
    rm -rf /ctx

LABEL containers.bootc=1 \
      org.opencontainers.image.title="omarchy-bootc acceptance overlay" \
      org.opencontainers.image.description="Disposable acceptance fixture layered on an exact candidate"

RUN bootc container lint --fatal-warnings
