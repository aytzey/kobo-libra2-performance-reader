# Kobo Libra 2 Performance Reader

An unofficial, device-specific optimization layer for [KOReader](https://github.com/koreader/koreader) on the Kobo Libra 2 (N418). It targets the complete reading session: fast PDF and EPUB reading, predictable touch input, optional text-to-speech, Bluetooth audio, and low-overhead device services.

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
- The book page stays primary; controls appear when needed and reserve their
  own space instead of covering text.
- File browsing is optimized for a large `/mnt/onboard/Books` folder.
- Background tuning is reversible when KOReader exits.
- Audio, Bluetooth, Wi-Fi, and USB-SSH remain opt-in rather than becoming
  permanent background services.

## Current status

| Area | Status |
| --- | --- |
| Device | Kobo Libra 2 / N418 |
| Primary reader | KOReader source snapshot with Libra 2 changes |
| Main document formats | EPUB and PDF |
| TTS / audio reading | Optional Google Cloud TTS generation, per-book cache, and native playback |
| Bluetooth audio | Device-side scan, pairing, reconnect, and headset controls |
| Native hot paths | BlitBuffer, MuPDF wrapper, CRe/XText, input, audio player |
| Kernel work | Linux 4.1.15 source patch and target config under `kernel/` |
| Device validation | Real-device validation exists in the private lab history |
| Public binary release | Deliberately not included in this source repository |

The lab snapshot was tested against Kobo firmware 4.38.23648. Firmware,
bootloader, storage state, and book structure can change results. Numbers from a
desktop benchmark are not device measurements.

## One-command workflow

The repository has one portable entry point for both packaging and deployment.
The first native build automatically downloads KOReader's pinned kobov4
toolchain, verifies its SHA-256, and keeps it under the ignored external
directory. No workstation-specific compiler path is required.

Linux and WSL use that toolchain directly. On macOS and Windows, the launcher
automatically creates a small Linux build container and runs the same build
inside it; Docker Desktop is the only host component it cannot install itself.
Python 3 is required on every host.

On macOS or Linux:

```sh
./kobo build
./kobo deploy
```

`deploy` finds a mounted KOBOeReader volume and keeps the existing backup and
rollback behavior. Use an explicit mount when auto-detection is not possible:

```sh
./kobo deploy --mount /Volumes/KOBOeReader
```

For USB or Wi-Fi SSH deployment:

```sh
./kobo deploy --usb-ssh --host 192.168.2.2 --port 2222
```

On Windows PowerShell, use the same commands through `kobo.cmd`:

```powershell
.\kobo.cmd build
.\kobo.cmd deploy
```

Set KOBO_CC when intentionally using a custom compiler. Set
KOBO_TOOLCHAIN_AUTO_FETCH=0 to prohibit downloads. Set KOBO_SKIP_NATIVE=1 only
when a source-only overlay is intentional; normal builds fail rather than
silently dropping the native player or USB helper.

## What is included

### Reader experience

- Libra 2-specific KOReader startup and power-profile tuning.
- Lower-cost page-turn, touch-event, and redraw paths.
- EPUB rendering through KOReader's CRe engine and PDF rendering through its
  MuPDF path, with device-specific native fast paths around both.
- One-handed reader controls with reduced menu startup work and progressive
  disclosure for infrequent actions.
- A focused Books folder flow with lighter file metadata handling.
- Lookup modules are kept out of the default reading path so highlighting and
  annotation remain the primary text interaction.
- Safer rerendering and document-lifecycle guards.
- When audio reading is active, the reader reserves bottom space for its
  controls so the player never sits on top of the page.

### TTS and audio reading

Audio reading is opt-in. Opening a book does not start synthesis, Bluetooth, or
playback on its own.

- The KOReader plugin calls the Google Cloud Text-to-Speech API. The API key is
  entered through a local setup page served by the Kobo; the device shows a
  plain IP address and port plus a short one-time password. The setup server
  stops after saving or cancelling, and the key stays in KOReader settings.
- Narration language is selected per book. The current built-in choices are
  Turkish (`tr-TR-Wavenet-E`) and English (`en-US-Wavenet-D`); the cache key
  includes the language and voice so changing language cannot reuse the wrong
  audio.
- Generation uses a 200-page window by default, but processes pages one at a
  time. Requests are split below the provider's character limit, line
  timepoints are stored when available, and completed pages are skipped.
- Each page keeps its text lines, audio segments, metadata, and completion
  marker. Partial pages can resume safely, and a selected range can be
  regenerated from the cache manager.
- A persistent generation bar shows the active range, current page, completed
  pages, errors, and percentage. It is visible while caching is active without
  covering the reading surface.
- The playback bar remains at the bottom of the reader and reserves layout
  space. It provides pause/resume, page return, resume-from-current-page,
  playback speed (`0.75x`, `1x`, `1.2x`, `1.5x`, `2x`), volume controls, and a
  line-level progress indicator when timepoints are available.
- The native C player decodes and streams audio through ALSA/BlueALSA, uses
  ARM NEON mixing where available, lowers its scheduling and I/O priority, and
  retries transient output failures without blocking the reader.
- Bluetooth discovery, pairing, forgetting, status, reconnect, and idle power
  management run on the Kobo itself. Headset play/pause, volume, previous,
  next, and stop events are handled through the device's available AVRCP input
  events.

The implementation lives in
[`koreader-src/plugins/ttsreader.koplugin/`](koreader-src/plugins/ttsreader.koplugin/)
and [`native/ttsreader-play.c`](native/ttsreader-play.c). The host smoke tests
cover the process helper, native player, speed/volume paths, and transient
audio behavior.

### Native reader and device code

- C hot paths for common grayscale and RGB tile conversions.
- Native EPUB/CRe string and hashing fast paths.
- Kobo-compatible input and ABI checks.
- Native TTS process control with pause, resume, seek, speed, volume, and
  Bluetooth recovery support.
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
kobo.py             Portable build/deploy command implementation
kobo, kobo.cmd      macOS/Linux and Windows launchers
Dockerfile.kobo-build Linux build environment for macOS and Windows
native/             Kobo-native C player and USB networking code
kernel/             GPLv2 kernel patch, target config, and build notes
scripts/            Build, package, deploy, benchmark, and test helpers
third_party/        Small explicitly-attributed third-party component(s)
docs/               Design and performance notes
LICENSES/           Full AGPL-3.0 and GPL-2.0 license texts
```

## Build the overlay

The repository is source-first. The build scripts provision the compatible
Kobo ARM toolchain and their compile-only ALSA SDK shim automatically. The
device still resolves its own libasound at runtime, so no host ALSA SDK or
private workstation path is required.

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
./scripts/test-usb-ssh-deploy.sh
./scripts/test-kobo-toolchain.sh
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
