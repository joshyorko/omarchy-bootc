#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: local-install-disk.sh IMAGE FILESYSTEM SIZE}"
filesystem="${2:?specify a filesystem}"
size="${3:?specify a disk size}"
case "$filesystem" in btrfs|ext4) ;; *) echo 'Expected btrfs or ext4.' >&2; exit 2 ;; esac
engine="${OMARCHY_DISK_INSTALL_ENGINE:-podman}"
case "$engine" in
    podman) installer=(sudo -n podman) ;;
    docker) installer=(docker) ;;
    *) echo 'OMARCHY_DISK_INSTALL_ENGINE must be podman or docker.' >&2; exit 2 ;;
esac
"${installer[@]}" info >/dev/null
for command in jq podman qemu-img skopeo; do
    command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done

output="${OMARCHY_LOCAL_DISK_DIR:-output/qcow2}"
mkdir -p -- "$output"
output="$(realpath -- "$output")"
if [[ -e "$output/disk.qcow2" || -e "$output/source.oci.tar" ]]; then
    echo "Existing disk or OCI in $output. Set OMARCHY_LOCAL_DISK_DIR to a new output directory." >&2
    exit 1
fi
work="$(mktemp -d "$output/.install.XXXXXXXX")"
docker_tag=
cleanup() {
    if [[ -n "$docker_tag" ]]; then docker image rm "$docker_tag" >/dev/null || true; fi
    rm -rf -- "$work"
}
trap cleanup EXIT

image_id="$(podman image inspect --format '{{.Id}}' "$image")"
image_id="sha256:${image_id#sha256:}"
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]]
source_sha="$(podman image inspect --format '{{ index .Labels "org.opencontainers.image.revision" }}' "$image")"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Image has no exact source revision. Build from a clean worktree." >&2
    exit 1
}
podman save --format oci-archive --output "$work/source.oci.tar" "$image_id"
skopeo inspect --raw "oci-archive:$work/source.oci.tar" >"$work/manifest.json"
manifest_digest="$(skopeo manifest-digest "$work/manifest.json")"
jq -e --arg id "$image_id" '.config.digest == $id' "$work/manifest.json" >/dev/null

# The runtime image only supplies the installer executable. Bootc always
# deploys the exact, separately verified OCI archive mounted read-only.
if [[ "$engine" == docker ]]; then
    tag="localhost/omarchy-bootc-install:${work##*.install.}"
    if docker image inspect "$tag" >/dev/null 2>&1; then
        echo "Docker installer tag already exists: $tag" >&2
        exit 1
    fi
    docker_tag="$tag"
    skopeo copy "oci-archive:$work/source.oci.tar" "docker-daemon:$docker_tag"
else
    "${installer[@]}" load --input "$work/source.oci.tar"
fi
loaded_id="$("${installer[@]}" image inspect --format '{{.Id}}' "${docker_tag:-$image_id}")"
[[ "sha256:${loaded_id#sha256:}" == "$image_id" ]]

truncate -s "$size" "$work/disk.raw"
"${installer[@]}" run --rm --privileged --pull=never \
    --security-opt label=disable \
    --mount "type=bind,source=$work/source.oci.tar,target=/input.oci.tar,readonly" \
    --mount "type=bind,source=$work/disk.raw,target=/disk.raw" \
    "$image_id" bootc install to-disk --source-imgref oci-archive:/input.oci.tar \
    --composefs-backend --via-loopback --filesystem "$filesystem" --wipe --bootloader systemd /disk.raw \
    2>&1 | tee "$output/bootc-install.log"
qemu-img convert -f raw -O qcow2 "$work/disk.raw" "$work/disk.qcow2"
qemu-img check "$work/disk.qcow2"
archive_checksum="$(sha256sum "$work/source.oci.tar" | cut -d ' ' -f1)"
jq -n --arg source_sha "$source_sha" --arg source_image "$image" --arg image_id "$image_id" \
    --arg manifest_digest "$manifest_digest" --arg archive_sha256 "$archive_checksum" \
    '{source_sha:$source_sha, source_image:$source_image, image_id:$image_id,
      manifest_digest:$manifest_digest, archive_sha256:$archive_sha256}' >"$work/image.json"
mv -- "$work/source.oci.tar" "$work/image.json" "$work/disk.qcow2" "$output/"
printf 'Disk and OCI receipt: %s\n' "$output"
