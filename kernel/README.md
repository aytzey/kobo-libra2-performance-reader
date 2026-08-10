# Kobo Libra 2 Kernel Changes

This directory contains the source-level kernel changes used during the Kobo
Libra 2 performance work.

## Target

- Linux `4.1.15`
- ARM i.MX/NTX Kobo target
- Target configuration: `configs/imx_v7_ntx_defconfig`
- Patch: `patches/libra2-linux-4.1.15-performance.patch`

The patch contains the meaningful source changes for flash read-ahead, block
scheduling, interactive CPU response, ARM assembler compatibility, touch
controller build safety, and device-tree compiler compatibility. Generated
compression assembly and binary build products are intentionally excluded.

## Applying the patch

Use a matching kernel source tree that you are permitted to use and
redistribute:

```sh
patch -p1 < kernel/patches/libra2-linux-4.1.15-performance.patch
cp kernel/configs/imx_v7_ntx_defconfig \
   arch/arm/configs/imx_v7_ntx_defconfig
make ARCH=arm imx_v7_ntx_defconfig
```

The patch is not a Kobo firmware update and must not be flashed by itself.
Validate the source base, bootloader expectations, image format, recovery path,
and hardware revision before building or deploying any kernel image.

Linux kernel source remains GPLv2. See [`../LICENSES/GPL-2.0.txt`](../LICENSES/GPL-2.0.txt)
and [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
