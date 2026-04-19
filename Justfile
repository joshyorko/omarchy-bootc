export image_name := env("IMAGE_NAME", "omarchy-bootc")
export default_tag := env("DEFAULT_TAG", "stable")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
export local_image := env("LOCAL_IMAGE", "localhost/" + image_name)

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

[private]
default:
    @just help

# ── Help / discoverability ───────────────────────────────────────────────────

# Show grouped recipes and practical notes for local usage.
[group('Utility')]
help:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "omarchy-bootc task runner"
    echo
    just --list --unsorted
    echo
    echo "Notes:"
    echo "  - build-qcow2 / rebuild-qcow2 use rootful podman and bootc install-to-disk (composefs)."
    echo "  - bootc-image-builder fallback remains as build-qcow2-bib / build-raw-bib."
    echo "  - run-vm-* requires /dev/kvm and a local container runtime capable of --privileged."
    echo "  - validate checks tool availability and required repo files before long builds."

# ── Syntax helpers ────────────────────────────────────────────────────────────

# Check Just syntax across all Justfiles
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
        echo "Checking syntax: $file"
        just --unstable --fmt --check -f "$file"
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just syntax across all Justfiles
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
        echo "Fixing syntax: $file"
        just --unstable --fmt -f "$file"
    done
    echo "Fixing syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# ── Utility ───────────────────────────────────────────────────────────────────

# Validate host prerequisites and required repository files.
[group('Utility')]
validate:
    #!/usr/bin/env bash
    set -euo pipefail

    REQUIRED_TOOLS=(podman just jq)
    OPTIONAL_TOOLS=(shellcheck shfmt ss qemu-img)

    for t in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "ERROR: required tool '$t' is not installed or not on PATH."
            exit 1
        fi
    done

    for t in "${OPTIONAL_TOOLS[@]}"; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "WARN: optional tool '$t' not found (some recipes may be unavailable)."
        fi
    done

    REQUIRED_FILES=(
        Containerfile
        custom/packages/base.packages
        custom/packages/omarchy.packages
        image/disk.toml
        build/10-base.sh
        build/20-omarchy.sh
        build/30-services.sh
    )

    for f in "${REQUIRED_FILES[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "ERROR: required file '$f' is missing."
            exit 1
        fi
    done

    if [[ ! -e /dev/kvm ]]; then
        echo "WARN: /dev/kvm not present. VM run recipes will be slow or may fail."
    fi

    echo "Validation complete."

# Clean build artefacts
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    touch _build
    find . -maxdepth 1 -name '*_build*' -exec rm -rf {} +
    rm -f previous.manifest.json changelog.md output.env
    rm -rf output/

# Lint all shell scripts with shellcheck
[group('Utility')]
lint:
    #!/usr/bin/env bash
    set -eoux pipefail
    if ! command -v shellcheck &>/dev/null; then
        echo "shellcheck not found — please install it."
        exit 1
    fi
    find . -iname "*.sh" -not -path './.git/*' -exec shellcheck "{}" ';'

# Format all shell scripts with shfmt
[group('Utility')]
format:
    #!/usr/bin/env bash
    set -eoux pipefail
    if ! command -v shfmt &>/dev/null; then
        echo "shfmt not found — please install it."
        exit 1
    fi
    find . -iname "*.sh" -not -path './.git/*' -exec shfmt --write "{}" ';'

# sudoif helper — runs a command as root when not already root
[private]
sudoif command *args:
    #!/usr/bin/bash
    function sudoif() {
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && \
             [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            /usr/bin/sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            /usr/bin/sudo "$@" || exit 1
        else
            echo "ERROR: sudo is required for this recipe."
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}

# ── Container image build ─────────────────────────────────────────────────────
# Build the OCI container image locally with podman

# Usage: just build [target_image] [tag]
[group('Build')]
build $target_image=local_image $tag=default_tag: validate
    #!/usr/bin/env bash
    set -eoux pipefail

    BUILD_ARGS=()
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    podman build \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --tag "${target_image}:${tag}" \
        .

# ── Bootc Image Builder helpers (fallback) ────────────────────────────────────

# Load a locally-built image into rootful podman (needed for BIB)
[private]
_rootful_load_image $target_image=local_image $tag=default_tag:
    #!/usr/bin/bash
    set -eoux pipefail

    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root — no need to copy image."
        exit 0
    fi

    set +e
    resolved_tag=$(podman inspect -t image "${target_image}:${tag}" | jq -r '.[].RepoTags.[0]')
    return_code=$?
    set -e

    USER_IMG_ID=$(podman images --filter reference="${target_image}:${tag}" --format "{{{{.ID}}}}")

    if [[ $return_code -eq 0 ]]; then
        ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "{{{{.ID}}}}")
        if [[ "$ID" != "$USER_IMG_ID" ]]; then
            COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
            just sudoif TMPDIR="${COPYTMP}" podman image scp \
                "${UID}@localhost::${target_image}:${tag}" \
                "root@localhost::${target_image}:${tag}"
            rm -rf "${COPYTMP}"
        fi
    else
        just sudoif podman pull "${target_image}:${tag}"
    fi

# Internal: run bootc-image-builder to produce a bootable image
[private]
_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    BUILDTMP=$(mktemp -p "${PWD}" -d -t _build-bib.XXXXXXXXXX)

    sudo podman run \
        --rm -it \
        --privileged \
        --pull=newer \
        --net=host \
        --security-opt label=type:unconfined_t \
        -v "$(pwd)/${config}:/config.toml:ro" \
        -v "${BUILDTMP}:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "${bib_image}" \
        --type "${type}" \
        --rootfs btrfs \
        "${target_image}:${tag}"

    mkdir -p output
    sudo mv -f "${BUILDTMP}"/* output/
    sudo rmdir "${BUILDTMP}"
    sudo chown -R "${USER}:${USER}" output/

# Internal: build the OCI image then run BIB
[private]
_rebuild-bib $target_image $tag $type $config: (build target_image tag) && (_build-bib target_image tag type config)

# ── Bootc native install targets ──────────────────────────────────────────────

# Build a qcow2 VM image via bootc install-to-disk (default)
[group('Build Virtual Machine Image')]
build-qcow2 $target_image=local_image $tag=default_tag filesystem="btrfs" size="20G": validate && (build target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    just _rootful_load_image "{{ target_image }}" "{{ tag }}"

    raw_path="output/raw/disk.raw"
    mkdir -p "$(dirname "${raw_path}")"
    if [[ ! -f "${raw_path}" ]]; then
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "{{ size }}" "${raw_path}"
        else
            truncate -s "{{ size }}" "${raw_path}"
        fi
    fi

    sudo podman run \
        --rm --privileged --pid=host \
        --pull=newer \
        -v /dev:/dev \
        -v /var/lib/containers:/var/lib/containers \
        -v /etc/containers:/etc/containers \
        -v "$(pwd):/data" \
        "{{ target_image }}:{{ tag }}" \
        bootc install to-disk --composefs-backend --via-loopback "/data/${raw_path}" --filesystem "{{ filesystem }}" --wipe --bootloader systemd

    if ! command -v qemu-img >/dev/null 2>&1; then
        echo "ERROR: qemu-img not found; install qemu-img or use build-raw. Raw image available at ${raw_path}."
        exit 1
    fi

    mkdir -p output/qcow2
    qemu-img convert -O qcow2 "${raw_path}" output/qcow2/disk.qcow2

# Build a raw VM image via bootc install-to-disk
[group('Build Virtual Machine Image')]
build-raw $target_image=local_image $tag=default_tag size="20G": validate && (build target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    just _rootful_load_image "{{ target_image }}" "{{ tag }}"

    raw_path="output/raw/disk.raw"
    mkdir -p "$(dirname "${raw_path}")"
    if [[ ! -f "${raw_path}" ]]; then
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "{{ size }}" "${raw_path}"
        else
            truncate -s "{{ size }}" "${raw_path}"
        fi
    fi

    sudo podman run \
        --rm --privileged --pid=host \
        --pull=newer \
        -v /dev:/dev \
        -v /var/lib/containers:/var/lib/containers \
        -v /etc/containers:/etc/containers \
        -v "$(pwd):/data" \
        "{{ target_image }}:{{ tag }}" \
        bootc install to-disk --composefs-backend --via-loopback "/data/${raw_path}" --filesystem "btrfs" --wipe --bootloader systemd

# Rebuild (OCI + qcow2) in one step using bootc install-to-disk
[group('Build Virtual Machine Image')]
rebuild-qcow2 $target_image=local_image $tag=default_tag filesystem="btrfs" size="20G": validate
    #!/usr/bin/env bash
    set -euo pipefail
    just build-qcow2 "{{ target_image }}" "{{ tag }}" "{{ filesystem }}" "{{ size }}"

# ── Bootc Image Builder (legacy) targets ─────────────────────────────────────

[group('Build Virtual Machine Image')]
build-qcow2-bib $target_image=local_image $tag=default_tag: validate && (_build-bib target_image tag "qcow2" "image/disk.toml")

[group('Build Virtual Machine Image')]
build-raw-bib $target_image=local_image $tag=default_tag: validate && (_build-bib target_image tag "raw" "image/disk.toml")

[group('Build Virtual Machine Image')]
rebuild-qcow2-bib $target_image=local_image $tag=default_tag: validate && (_rebuild-bib target_image tag "qcow2" "image/disk.toml")

# ── Run VM ────────────────────────────────────────────────────────────────────

# Internal: launch a VM from a previously-built disk image via qemux/qemu
[private]
_run-vm $target_image $tag $type $config:
    #!/usr/bin/bash
    set -eoux pipefail

    image_file="output/${type}/disk.${type}"

    if [[ ! -f "${image_file}" ]]; then
        just "build-${type}" "${target_image}" "${tag}"
    fi

    if ! command -v ss >/dev/null 2>&1; then
        echo "ERROR: 'ss' command not found (install iproute2)."
        exit 1
    fi

    port=8006
    while grep -q ":${port}" <<< "$(ss -tunalp)"; do
        port=$(( port + 1 ))
    done
    echo "Using port: ${port}"
    echo "Connect to: http://localhost:${port}"

    run_args=(
        --rm --privileged
        --pull=newer
        --publish "127.0.0.1:${port}:8006"
        --env "CPU_CORES=4"
        --env "RAM_SIZE=8G"
        --env "DISK_SIZE=64G"
        --env "TPM=Y"
        --env "GPU=Y"
        --device=/dev/kvm
        --volume "${PWD}/${image_file}:/boot.${type}"
    )

    (sleep 30 && xdg-open "http://localhost:${port}") &
    podman run "${run_args[@]}" docker.io/qemux/qemu

# Run the qcow2 VM locally
[group('Run Virtual Machine')]
run-vm-qcow2 $target_image=local_image $tag=default_tag: validate && (_run-vm target_image tag "qcow2" "image/disk.toml")

# Run the raw VM locally
[group('Run Virtual Machine')]
run-vm-raw $target_image=local_image $tag=default_tag: validate && (_run-vm target_image tag "raw" "image/disk.toml")

# Spawn a VM with systemd-vmspawn (alternative to qemux)
[group('Run Virtual Machine')]
spawn-vm type="qcow2" ram="6G":
    #!/usr/bin/env bash
    set -euo pipefail
    systemd-vmspawn \
        -M "omarchy-bootc" \
        --console=gui \
        --cpus=2 \
        --ram="$(echo {{ ram }} | /usr/bin/numfmt --from=iec)" \
        --network-user-mode \
        --vsock=false --pass-ssh-key=false \
        -i ./output/**/*.{{ type }}
