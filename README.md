# Kobo Libra 2 Performance Reader

An unofficial, device-specific optimization layer for [KOReader](https://github.com/koreader/koreader) on the Kobo Libra 2 (N418), focused on fast PDF and EPUB reading, predictable touch input, and low-overhead device services.

This project is not affiliated with Kobo, Rakuten, or the KOReader maintainers.

## Why this exists

The Libra 2 is a capable reading device with a modest CPU, slow flash storage,
an E Ink display, and limited memory. General-purpose defaults leave avoidable
work on the critical path. This repository collects the device-specific changes
that were measured and tested on a real Libra 2 instead of replacing KOReader's
document engines without evidence.

The primary target is a calm, responsive reading session:

- EPUB and PDF open/render paths stay local and native.
- Page turns and touch events avoid unnecessary work.
- File browsing is optimized for a large `/mnt/onboard/Books` folder.
- Background tuning is reversible when KOReader exits.
- Optional audio, Bluetooth, Wi-Fi, and USB-SSH paths remain explicit rather
  than becoming permanent background services.

## Current status

| Area | Status |
| --- | --- |
| Device | Kobo Libra 2 / N418 |
| Primary reader | KOReader source snapshot with Libra 2 changes |
| Main document formats | EPUB and PDF |
| Native hot paths | BlitBuffer, MuPDF wrapper, CRe/XText, input, audio player |
| Kernel work | Linux 4.1.15 source patch and target config under `kernel/` |
| Device validation | Real-device validation exists in the private lab history |
| Public binary release | Deliberately not included in this source repository |

The lab snapshot was tested against Kobo firmware 4.38.23648. Firmware,
bootloader, storage state, and book structure can change results. Numbers from a
desktop benchmark are not device measurements.

## What is included

### Reader and UI

- Libra 2-specific KOReader startup and power-profile tuning.
- Lower-cost page-turn and touch-event paths.
- Simpler one-handed reader controls and reduced menu startup work.
- A focused Books folder flow with lighter file metadata handling.
- Lookup modules kept out of the default reading path.
- Safer rerendering and document-lifecycle guards.

### Native code

- C hot paths for common grayscale and RGB tile conversions.
- Native EPUB/CRe string and hashing fast paths.
- Kobo-compatible input and ABI checks.
- An optional native TTS player with pause, seek, speed, volume, and Bluetooth
  recovery support.
- USB networking and SSH helper code for development and recovery.

### Kernel

`kernel/patches/libra2-linux-4.1.15-performance.patch` contains the source
changes used for the Libra 2 kernel experiment. The patch covers:

- MMC read-ahead for sequential document reads.
- Deadline I/O scheduling changes for flash-backed reading workloads.
- Interactive CPU governor thresholds for shorter foreground bursts.
- ARM assembler/toolchain compatibility fixes.
- Touch-controller firmware build-safety changes.
- Device-tree compiler compatibility fixes.

`kernel/configs/imx_v7_ntx_defconfig` records the target configuration used by
the source snapshot. The patch is source material, not a firmware image. Do not
flash a kernel without a verified recovery path and a matching device build.

## Repository layout

```text
koreader-src/       Vendored KOReader source and device-specific changes
native/             Kobo-native C player and USB networking code
kernel/             GPLv2 kernel patch, target config, and build notes
scripts/            Build, package, deploy, benchmark, and test helpers
third_party/        Small explicitly-attributed third-party component(s)
docs/               Design and performance notes
LICENSES/           Full AGPL-3.0 and GPL-2.0 license texts
```

## Build the overlay

The repository is source-first. A compatible Kobo ARM toolchain is required for
native libraries; the build scripts accept environment overrides instead of
embedding workstation paths.

```sh
./scripts/package-libra2-overlay.sh
```

The generated ZIP is written to `dist/`, which is intentionally ignored. Keep
generated archives and device backups outside commits. Before deploying to a
real device, inspect the package and keep a known-good KOReader backup.

## Test the host-safe paths

```sh
./scripts/test-libra2-optimize.sh
./scripts/test-overlay-deploy.sh
./scripts/test-ttsreader-helper-host.sh
./scripts/test-ttsreader-player-host.sh
```

The tests validate shell behavior, package/deploy safety, native player smoke
behavior, and source-level regression guards. Final performance and battery
claims require a repeatable Libra 2 fixture and the exact firmware version.

## Kernel source workflow

The public repository contains the kernel changes without a prebuilt `zImage`:

1. Obtain the matching Kobo/NTX Linux 4.1.15 source from a source you are
   permitted to redistribute or use.
2. Record the vendor source identifier before applying the patch.
3. Apply `kernel/patches/libra2-linux-4.1.15-performance.patch` with `patch -p1`.
4. Use `kernel/configs/imx_v7_ntx_defconfig` as the target configuration.
5. Build, inspect, and test the result before considering deployment.

The original lab snapshot did not retain the vendor kernel Git commit. That
provenance gap is documented rather than hidden; a reproducible kernel release
must close it first. See [`kernel/README.md`](kernel/README.md).

## Safety and scope

- This is an unofficial Kobo modification and may void support or warranty.
- It is not a firmware replacement and is not a promise of brick-proof
  installation.
- Never commit books, screenshots of copyrighted pages, device logs, Wi-Fi
  credentials, SSH keys, API keys, or generated caches.
- TTS providers and their credentials are user-configured. No cloud key belongs
  in this repository.
- DRM circumvention and redistribution of books are outside this project.

## Contributing

Small, measured changes are preferred. Every performance claim should name the
device, firmware, fixture, baseline, and command used to obtain it. Kernel
changes must include the source base identifier and preserve the Linux kernel
copyright and license notices.

See [`CONTRIBUTING.md`](CONTRIBUTING.md), [`UPSTREAM.md`](UPSTREAM.md), and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) before opening a change.

## License

Project-owned reader changes are released under the GNU Affero General Public
License version 3.0. KOReader and its upstream components retain their own
copyright and AGPLv3 notices. The Linux kernel patch remains subject to the
Linux kernel's GPLv2 terms. Third-party components, fonts, icons, and data keep
the licenses shipped beside them.

Read [`LICENSE`](LICENSE), [`LICENSES/AGPL-3.0.txt`](LICENSES/AGPL-3.0.txt),
[`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt), and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
