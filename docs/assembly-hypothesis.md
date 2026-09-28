# Independent Omarchy assembly handoff

The `assembly` target is the package and provenance boundary after the
selected Bootcrew/Arch/bootc foundation. The dedicated workflow in
`.github/workflows/assembly.yml` checks out one exact source head, proves the
foundation, builds only `quattro-assembly`, verifies the assembly receipt and
archive against that head, and checks that the image carries the resolved
package manifest and provenance files.

This workflow does not invoke QEMU, install a disk, or run the expensive
graphical acceptance path. Its uploaded archive and receipt are an immutable
handoff for the later integration and runtime stages; they are not Gate 1--6
acceptance evidence by themselves.
