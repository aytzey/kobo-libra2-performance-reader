# Upstream and Provenance

## KOReader

The source snapshot is based on the KOReader `v2026.03` release line.

| Upstream component | Identifier |
| --- | --- |
| KOReader main repository tag | `v2026.03` |
| KOReader main commit | `825b9bced0eb666b45af4208e1c0095b88d38b0d` |
| `base` submodule | `7a46ea3812539083ee25b06f0c81ac58b1356ee0` |
| Android LuaJIT launcher | `3e149d809aa5d63f4a6a76ffb98e0c71961f6de0` |
| Ubuntu Touch SDL template | `1d0cd7583c27025a69e340ac77cab3c53cdef8ba` |
| KOReader test data | `c3b5d06e1ae8ea088bd898b0e7f9da3753d0d86c` |

This public tree vendors the source so that the Libra 2 changes can be read in
one place. Upstream copyright and license notices remain in the tree.

## Kernel

The kernel work targets Linux 4.1.15 and an i.MX/NTX Kobo configuration. The
private lab retained a complete working source snapshot and a generated diff,
but not the vendor Git commit that produced the base tree. The public patch is
therefore explicitly labeled as a source patch against the lab's 4.1.15 base.

Before publishing a reproducible kernel image, record:

- the exact vendor source URL and commit or archive checksum;
- the compiler, binutils, and sysroot versions;
- the final `.config` checksum;
- the resulting image checksum and device recovery procedure.

Until those fields are complete, the source patch is the authoritative public
kernel artifact and the private prebuilt image is not redistributed.
