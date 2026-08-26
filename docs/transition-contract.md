# Cross-distro bootc transition contract

This is a separate supported entry path from the fresh Omarchy ISO installer.
The package backend of the source OS is not converted: `bootc switch` replaces
the image payload, while `/var`, `/var/home`, and other mutable machine state
need an explicit transition boundary.

## Supported sources

The transition helper recognizes Bluefin, Dakota, and an existing Omarchy
bootc deployment. It refuses an unknown source instead of guessing what its
persistent state means.

Before switching, the source-side helper must run:

```text
preflight -> capture-state -> backup -> bootc switch -> reboot
```

`capture-state` records source identity, user/group IDs, home-directory
ownership, and non-secret configuration metadata. It deliberately excludes
password hashes, keys, tokens, and the contents of user data. `backup` copies
only the bounded configuration surfaces that the target adoption flow may
touch; it never snapshots or replaces a whole home.

The actual image transition remains the upstream operation:

```bash
bootc switch <target-image>
```

The helper requires an explicit `--confirm` for that operation and does not
reboot automatically.

## Target first boot

The Quattro image enables `omarchy-adopt-existing-user.service`. It runs before
the display manager only when the image was not installed by the upstream
Omarchy ISO and no adoption state exists.

The bounded adoption flow:

1. discovers direct `/var/home` directories owned by a human UID;
2. adopts exactly one user, or stops for an explicit `/etc/omarchy/adoption-user`
   selection when there are multiple homes;
3. creates the matching local account without creating or replacing its home;
4. asks for a password when the new image has no account record;
5. backs up known conflicting configuration;
6. runs the upstream `omarchy-provision-user --first-install` as that user;
7. restores pre-existing user-owned configuration while retaining generated
   replacements under the adoption rollback record.

No whole `/etc/skel` replay, home deletion, user-data migration, or local
replacement for an Omarchy command is allowed. An ISO install writes
`/var/lib/omarchy-bootc/installer-origin`, so its upstream installer and
deferred-provisioning paths remain authoritative and skip adoption.

## Independent recovery

`/usr/bin/omarchy-adoption-rollback` restores the recorded configuration and
leaves post-adoption files under `rollback-current`. It is independent of
`bootc rollback` because `/var/home` persists across image deployment
rollback. The transition helper's `recover --confirm` invokes this mutable
state recovery only; deployment rollback remains an explicit separate bootc
operation.

## Acceptance matrix

Static checks are not runtime acceptance. The required matrix is:

| Source | Transition | Target proof |
| --- | --- | --- |
| Bluefin | preflight, backup, switch, reboot | existing user/data preserved; upstream finalizer; Quattro session |
| Dakota | preflight, backup, switch, reboot | existing user/data preserved; upstream finalizer; Quattro session |
| Omarchy bootc | ordinary image switch | normal upgrade path; no adoption replay |
| Unknown bootc | refused before switch | no mutation |

For Bluefin and Dakota, the test must also exercise an independent adoption
rollback and a separate bootc deployment rollback. Fresh ISO tests remain the
upstream Omarchy acceptance harness and are covered by the installer parity
contract, not by this transition helper.
