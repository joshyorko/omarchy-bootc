FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 update \
 && apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 install -y --no-install-recommends \
    ca-certificates curl git jq podman buildah skopeo sudo python3 shellcheck \
    ovmf qemu-system-x86 qemu-utils sshpass openssh-client uidmap fuse-overlayfs \
    time util-linux iproute2 zstd xz-utils btrfs-progs make gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/containers \
 && printf '[storage]\ndriver="overlay"\ngraphroot="/builds/containers"\nrunroot="/run/containers/storage"\n' > /etc/containers/storage.conf \
 && printf '[engine]\ncgroup_manager="cgroupfs"\nevents_logger="file"\n' > /etc/containers/containers.conf
