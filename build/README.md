# build/

Build scripts are numbered and executed in order during `podman build`.

| Script | Purpose |
|---|---|
| `10-base.sh` | Install core packages (including boot-critical kernel/initramfs bits) and create default VM user (`omarchy`) |
| `20-omarchy.sh` | Install minimal Hyprland baseline and stage greetd config |
| `30-services.sh` | Enable core services including `greetd` and first-boot unit |

Packages are declared in `custom/packages/`.

This remains a technical POC focused on a first credible VM boot/login path,
not full Omarchy parity.


Note: `bootc` package installation is currently deferred because CI Arch repos do not currently resolve it for this project.
