ARG CANDIDATE_IMAGE
FROM ${CANDIDATE_IMAGE}

# This is a disposable runtime fixture layered on one already-built candidate.
# It must never be published as the normal Omarchy image.
COPY build/acceptance-firstboot.sh /ctx/build/acceptance-firstboot.sh
COPY build/acceptance-firstboot.service /ctx/build/acceptance-firstboot.service
COPY build/stage-acceptance-node.sh /ctx/build/stage-acceptance-node.sh
COPY build/25-quattro-user.sh /ctx/build/25-quattro-user.sh

# Only this disposable layer permits the SSH harness through product UFW.
# Offline rule writing must not apply the rules to the build host's firewall.
RUN grep -Fxq ENABLED=yes /etc/ufw/ufw.conf && \
    sed -i 's/^ENABLED=yes$/ENABLED=no/' /etc/ufw/ufw.conf && \
    ufw allow 22/tcp comment 'disposable acceptance SSH' && \
    sed -i 's/^ENABLED=no$/ENABLED=yes/' /etc/ufw/ufw.conf

RUN --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/stage-acceptance-node.sh && \
    bash /ctx/build/25-quattro-user.sh && \
    install -d -m 0755 /etc/sddm.conf.d && \
    printf '%s\n' \
        '[Autologin]' \
        'User=omarchy' \
        'Session=omarchy.desktop' \
        'Relogin=true' \
        > /etc/sddm.conf.d/90-omarchy-acceptance.conf && \
    rm -rf /ctx

LABEL containers.bootc=1 \
      org.opencontainers.image.title="omarchy-bootc acceptance overlay" \
      org.opencontainers.image.description="Disposable acceptance fixture layered on an exact candidate"

RUN bootc container lint --fatal-warnings
