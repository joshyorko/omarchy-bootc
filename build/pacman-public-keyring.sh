#!/usr/bin/env bash
# Local signing keys exist only in the RUN's tmpfs. Persist public trust only.
set -euo pipefail
ring="${PACMAN_GNUPG_DIR:-/etc/pacman.d/gnupg}"
public="${PACMAN_PUBLIC_DIR:-/usr/share/omarchy-bootc/pacman-public}"

require_tmpfs_ring() {
    [[ "${PACMAN_KEYRING_ALLOW_NON_TMPFS_FOR_TEST:-0}" == 1 ]] && return 0
    [[ "$(findmnt -T "$ring" -no FSTYPE)" == tmpfs ]] || {
        echo 'Refusing to generate pacman signing keys outside build-only tmpfs' >&2
        exit 1
    }
}

assert_no_secret_material() {
    local dir="$1"
    if [[ -d "$dir/private-keys-v1.d" ]]; then
        [[ -z "$(find "$dir/private-keys-v1.d" -type f -print -quit)" ]] || {
            echo "Secret key material present in $dir/private-keys-v1.d" >&2
            exit 1
        }
    fi
    [[ ! -e "$dir/secring.gpg" ]] || {
        echo "Secret keyring present at $dir/secring.gpg" >&2
        exit 1
    }
    [[ ! -e "$dir/random_seed" ]] || {
        echo "GPG random_seed present at $dir/random_seed" >&2
        exit 1
    }
    if find "$dir" -maxdepth 2 \( -name 'S.gpg-agent*' -o -name '*.key' \) -print -quit | grep -q .; then
        echo "Secret agent socket or key file present in $dir" >&2
        exit 1
    fi
}

case "${1:?Expected init, export or restore}" in
    init)
        require_tmpfs_ring
        pacman-key --init
        pacman-key --populate archlinux
        ;;
    export)
        require_tmpfs_ring
        install -d -m 0755 "$public"
        gpg --batch --homedir "$ring" --export-options export-local-sigs --export >"$public/public-keys.gpg"
        gpg --batch --homedir "$ring" --export-ownertrust >"$public/ownertrust.txt"
        test -s "$public/public-keys.gpg"
        test -s "$public/ownertrust.txt"
        chmod 0644 "$public/public-keys.gpg" "$public/ownertrust.txt"
        gpgconf --homedir "$ring" --kill all || true
        ;;
    restore)
        rm -rf -- "$ring"
        install -d -m 0700 "$ring"
        gpg --batch --no-autostart --homedir "$ring" --import-options import-local-sigs --import "$public/public-keys.gpg"
        gpg --batch --no-autostart --homedir "$ring" --import-ownertrust "$public/ownertrust.txt"
        gpg --batch --no-autostart --homedir "$ring" --check-trustdb
        gpgconf --homedir "$ring" --kill all || true
        rm -f -- "$ring/random_seed" "$ring"/S.gpg-agent*
        assert_no_secret_material "$ring"
        ;;
    *) exit 2 ;;
esac
