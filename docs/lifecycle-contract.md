# Gate 3 and Gate 5 lifecycle contract

The Omarchy VM acceptance harness in \`scripts/ci/vm-smoke.sh\` treats the
lifecycle path as a required gate for the \`omarchy\` profile.

## Gate 3: exact A → B → rollback

The harness builds a second OCI artifact from the exact candidate image. It
records each artifact's OCI manifest digest and then proves:

1. A is booted before the transition.
2. B is staged from an explicit OCI archive.
3. B reboots and its booted digest is exactly B.
4. The B payload is present.
5. User/plugin state hashes are unchanged.
6. Rollback reboots to A and its booted digest is exactly A.
7. The same user/plugin state hashes and plugin directory survive rollback.

A status field is accepted only from the selected bootc schema slot
(\`.status.booted\` or \`.status.staged\`); the harness never uses a first/second
digest heuristic.

## Gate 5: updater-owned staging

Gate 5 starts from the rolled-back A deployment and invokes:

\`\`\`text
omarchy update -y
\`\`\`

There is no direct \`bootc switch\` or other pre-stage in this section. The
updater must call \`bootc upgrade --check\` and the bootc upgrade operation,
then the harness verifies the exact B digest after reboot. A transparent trace
of those bootc calls is retained.

The harness snapshots the real pacman database files, pacman package set, and
pacman log before the updater, after the updater, and after reboot. Any
difference fails the gate; a live \`pacman -Syu\` is not an accepted update
mechanism.

## Origin and receipts

The initial \`.spec.image.image\` value from \`bootc status --format=json\` is
always recorded. If \`OMARCHY_EXPECTED_TRACKING_REF\` is supplied, it must match
exactly. Alternatively, setting \`OMARCHY_ASSERT_TESTING_REF=1\` requires the
configured ref to end in \`:testing\`. Local OCI-only candidate runs may leave
this assertion disabled because their configured origin is not the production
GHCR stream.

A successful run writes:

\`\`\`text
gate-3-5.receipt.json
\`\`\`

The receipt contains the source SHA, A/B digests, configured origin values,
user/plugin state hashes, pacman DB/log snapshot hashes, bootc trace hash, and
the explicit \`gate5.pre_stage = "none"\` result. A plain \`gate-3-5.receipt\`
marker is retained only as a compact CI summary.


## Gate 5 tracking stream

The VM harness installs the embedded A artifact with
`ghcr.io/joshyorko/omarchy-bootc:testing` as its configured future origin.
For the pre-publication acceptance run, a disposable host registry mirrors
that exact prefix to the controlled B artifact. The guest uses an explicit
insecure registry mirror configuration; the recorded origin remains
`:testing`. Gate 5 therefore exercises the real `omarchy update` →
`bootc upgrade --check`/ `upgrade` path without staging B beforehand.
The mirror is removed during harness cleanup and is not a release artifact.
