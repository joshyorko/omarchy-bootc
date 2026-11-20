#!/usr/bin/env bash
set -euo pipefail

# omarchy-adoption-rollback preserves the post-adoption tree under the
# rollback-current directory before restoring the recorded pre-adoption state.
exec /usr/lib/omarchy/omarchy-adopt-existing-user.sh --rollback "$@"
