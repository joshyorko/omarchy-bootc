# Omarchy assembly/provenance boundary

The 'quattro-assembly' target runs only the pinned Omarchy package installation and
verify-quattro-payload.sh. Its CI contract checks the package manifest,
package metadata, repository configuration, and optional resolver report, then
exports an archive and receipt bound to the immutable foundation image ID.

Bootcrew ownership cleanup (30-bootc-ownership.sh), adoption, updater dispatch,
and transition run in 'quattro-base'/'quattro-integration'. The assembly target
therefore does not run fatal bootc lint while its package transactions have
intentionally left runtime-only directories populated. Fatal
bootc container lint --fatal-warnings remains mandatory on the foundation,
integration, acceptance, final, and published image boundaries.

The candidate workflow is ordered:

1. foundation contract and immutable handoff;
2. package/provenance assembly contract and immutable handoff;
3. integration contract, including updater dispatch and fatal lint;
4. final candidate export;
5. disk/UEFI/QEMU acceptance.

A failure in any lower stage prevents the expensive final candidate and VM path.
