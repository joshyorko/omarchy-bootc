#!/usr/bin/env bash

verify_bootc_initramfs_reports() {
    local modules_report="${1:?initramfs module report path is required}"
    local contents_report="${2:?initramfs content report path is required}"
    local required

    for required in ostree bootc; do
        grep -Fxq "${required}" "${modules_report}" || return 1
    done

    for required in \
        usr/lib/ostree/ostree-prepare-root \
        usr/lib/systemd/system/ostree-prepare-root.service \
        usr/lib/bootc/initramfs-setup \
        usr/lib/systemd/system/bootc-root-setup.service; do
        grep -Fq "${required}" "${contents_report}" || return 1
    done
}
