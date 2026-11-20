# Bootc/Arch foundation hypothesis

This is the lower-stage contract for the selected release tuple. It is intentionally
separate from Omarchy package assembly and from VM acceptance.

## Inputs compared

| Input | Selected/current evidence | Consequence |
| --- | --- | --- |
| bootc | stable v1.16.13, source 'fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60' | The stable packaging contract requires composefs, ostree, podman, skopeo, and '/usr/bin/chcon'; it is not the moving 'main' branch. |
| Bootcrew | pinned mono '5f048fa65a94daefc814d3cdd941d8d1e113c09e', Arch bootstrap digest 'sha256:0de35fe2ee793494ccfc99b202f6b30215b078baf2b082e9ccb027840c534fc1' | Provides the Arch root relocation, dracut/initramfs, '/sysroot', '/ostree', and composefs configuration. Its upstream Arch Containerfile does not provide SELinux-aware 'chcon' and only runs non-fatal lint. |
| known-working Arch/native-composefs reference | 'oci-native/archlinux' commit '28909acc39ba2a1bd8a1e88d01e265b4c995fcc3', bootc v1.16.10 | Builds bootc with stock Arch build dependencies, uses the same native-composefs/Bootcrew shape, and proves fatal lint/runtime operation for that older bootc package. It does not establish that v1.16.13's '/usr/bin/chcon' requirement is satisfied. |
| Arch package universe | Current Arch 'coreutils' omits SELinux support; the optional 'coreutils-selinux' package is an AUR alternative | A stock Arch coreutils install cannot satisfy bootc v1.16.13's hard 'chcon' runtime requirement. |

## Decision

For this exact v1.16.13 + Quattro tuple, retaining a small, source-pinned
SELinux userspace ('libsepol' and 'libselinux') plus the single SELinux-aware
coreutils 'chcon' binary is the smallest adaptation that satisfies the
selected bootc runtime contract while preserving the pinned Arch/Bootcrew
root. It is not being presented as a general Arch SELinux distribution.

The implementation is accepted only if the 'foundation' target passes
'build/foundation-contract.sh' and fatal 'bootc container lint'. If that
isolated target fails, the next move is to replace this adaptation with the
smallest complete 'coreutils-selinux' package/source alternative; another
Omarchy/VM build is not a foundation debugger.

## Required proof

The foundation target must independently prove:

- bootc v1.16.13 is built from the recorded revision;
- 'bootc', 'chcon', ostree, podman, skopeo, and initramfs tools have all
  runtime libraries resolved;
- composefs is installed and enabled in 'prepare-root.conf';
- '/sysroot', '/ostree', dracut's '51bootc', and an ostree dracut module exist;
- fatal 'bootc container lint' passes.

Its OCI archive and receipt are exported under an exact source-head/target
identity so the Omarchy assembly stage can be inspected separately.
