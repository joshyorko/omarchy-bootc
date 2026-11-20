# Pinned migration runner

`omarchy-migrate-ac2690cd.sh` is byte-for-byte upstream
[`bin/omarchy-migrate` at ac2690cd7be4f47e4a255f5e2e78d904d436b068](https://github.com/omacom/omarchy/blob/ac2690cd7be4f47e4a255f5e2e78d904d436b068/bin/omarchy-migrate).
Upstream is MIT licensed. SHA-256:
`0c14cb7853174d5289172496e22c1bd444b20c00c1aefd589e1faa3ae6941abe`.

The finalizer regression checks these bytes before redirecting only the pacman
lock path and elapsed wait into its disposable fixture. Discovery, pending
queries, script execution and completion markers run the real pinned code.
