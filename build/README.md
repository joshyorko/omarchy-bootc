# build/

`Containerfile`, not filename numbering, defines the effective build graph:

```text
stable-base -> bootcrew-system -> quattro-assembly -> quattro-base -> quattro-integration -> final
                           \-> foundation (sibling verification target)
```

`bootc-builder` compiles the pinned bootc payload copied into `bootcrew-system`.
The latter explicitly installs sudo, creates password-required wheel policy,
and validates both the drop-in and complete sudoers configuration with visudo.
Product update elevation therefore does not depend on an acceptance fixture.
The official package's command-scoped passwordless helpers (`50-asdcontrol`,
`omarchy-dns`, `omarchy-theme-browser`, `omarchy-tzupdate`) remain unchanged.
Password-required wheel administration is distinct from these bounded desktop
operations. Final rejects acceptance credentials and unrestricted literal
`NOPASSWD: ALL` grants, not every `NOPASSWD` tag.

| Script | Effective purpose |
|---|---|
| `20-quattro.sh` | Install the official package, authoritative base manifest and required desktop PulseAudio compatibility; resolve the optional manifest |
| `30-bootc-ownership.sh` | Apply upstream service/firewall configuration and restore declared-kernel boot/initramfs ownership |
| `install-bootc-update.sh` | Install immutable bootc update dispatch and login finalization |
| `foundation-contract.sh` | Verify the sibling foundation's actual runtime dependencies and fatal lint |
| `acceptance-dependencies.sh` | Check actual executables, immutable payload, kernel/header ownership and compatibility, enabled desktop services, and supported bootc CLI |
| `verify-publishable-image.sh` | Reject acceptance credentials in final |
| `stage-acceptance-node.sh`, `25-quattro-user.sh`, `acceptance-firstboot.sh` | Stage and provision disposable acceptance fixtures only |

The obsolete `10-base.sh`, `20-omarchy.sh`, `30-services.sh` and
`custom/packages/{base,omarchy}.packages` have been removed. They were not wired
into this graph. Package authority is now the effective `bootcrew-system`
package command plus `/usr/share/omarchy/install/omarchy-{base,other}.packages`
from the pinned official package.

`bootcrew-system` installs `linux` and `linux-headers` together and declares
`linux` in image-owned `/usr/share/omarchy-bootc/kernel-package`. Final initramfs
generation selects the single module tree whose `pkgbase` matches that declaration
and passes its release explicitly to dracut; it never selects the build host's
kernel. Preflight requires matching installed kernel/header package versions,
package-owned `pkgbase`, `vmlinuz` and header `kernel.release`, and a header
release matching that image module tree. The guest bootc acceptance adapter also
requires this declared kernel to be the running kernel.

`pipewire-pulse` is an explicit required desktop dependency even though upstream
lists it in `omarchy-other.packages`; its package install enables the user socket.
The rest of that manifest remains resolution-only, preserving optional,
mutually incompatible hardware policy.

`30-bootc-ownership.sh` invokes the package-owned
`/usr/share/omarchy/install/config/firewall.sh` after verifying UFW starts disabled.
Upstream writes default-deny incoming, default-allow outgoing, LocalSend and
Docker DNS/protection rules, sets `ENABLED=yes`, and enables `ufw.service` without
activating the build host's firewall. No product SSH exception or new
passwordless administration policy is added.

## Dependency preflight phases

Run `/usr/lib/omarchy-bootc/acceptance-dependencies.sh PHASE`:

- `final`: root image context; actual product/update/guest command availability,
  immutable wrappers, native shell/plugin/skills/session files, matching declared
  kernel/headers, persistently enabled core services including UFW, `ENABLED=yes`,
  the package-owned `pipewire-pulse.service`, password-required wheel administration,
  and absence of acceptance/unrestricted sudo credentials. Installed and run in
  `quattro-integration`, inherited by final.
- `overlay`: root disposable-image context; same product command, payload,
  kernel/header and service checks, plus firstboot executable/unit and
  checksum-valid staged Node archive.
  It does not require an account, home, ready marker, running systemd, or display.
- `guest`: run as the provisioned `omarchy` SSH user after firstboot readiness.
  Additionally checks working noninteractive fixture sudo, visudo, account HOME,
  finalization/theme/config state, provisioned skills, and executable user Node.
  Node is a post-provision mise install, not a final-image `/usr/bin/node` dependency.

The disposable `scripts/ci/acceptance-overlay.Containerfile` derives from the
exact final candidate, not the sibling foundation or the development acceptance
target. Firstboot creates `/etc/sudoers.d`, validates its passwordless fixture
and the complete policy, and proves elevation before provisioning.
Only this disposable overlay adds incoming TCP port 22 for the SSH harness.
It temporarily sets UFW's configuration to disabled while writing the rule,
then restores `ENABLED=yes`; it does not apply rules to the build host.

The executable inventory covers product update (`sudo`, `flock`, `bootc`, `skopeo`, `jq`,
account/file tools), firstboot (shadow/runuser/mise/archive tools), guest-native
(Git/pacman, coreutils/text tools, user systemd/journal/DBus, inotify, Hyprland,
Quickshell, native plugin/agent helpers), the unchanged upstream graphical suite
(OCR, clipboard, media/printing status, native application and selector helpers),
and remote VM checks (`pacman-conf`, archive/hash/comparison tools and bootc).
Bootc help probes validate status,
upgrade, switch, rollback and install-to-disk options without network or staging.
Host QEMU, firmware, podman, SSH/sshpass and rootless handoff requirements remain
the harness's responsibility. Live graphics/IPC, digest identity, actual
update/rollback/reboot persistence are not certified by preflight.

The upstream Hyprland session prepends `/usr/share/omarchy/bin` to `PATH`.
The update installer therefore projects the three public update entry points
(`omarchy`, `omarchy-update`, and `omarchy-update-available`) from their
package-owned symlinks targeting `/usr/bin` to immutable bootc wrappers in
`/usr/local/bin`; the package-owned executable bytes remain unchanged. The
final-image preflight exercises the graphical `omarchy update` route with both
argument rejection and a no-stage `-y` check, then invokes the literal
`omarchy-update-available` command under the same PATH.

`tests/test-acceptance-dependencies.sh` covers absent/non-executable/user-local
commands, invalid phases, scoped versus unrestricted sudo grants, incompatible
kernel/header versions and releases, payload ownership, missing kernels/headers,
disabled services/UFW and missing PulseAudio compatibility. Service enablement
uses real offline systemd fixtures rather than source or documentation assertions.
Runtime image checks are still required after integration.
