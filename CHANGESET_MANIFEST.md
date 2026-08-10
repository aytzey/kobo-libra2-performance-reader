# Public Source Manifest

This repository is a cleaned public source release derived from the private
Kobo Libra 2 optimization lab. It contains source, tests, documentation, and a
reproducible starting point for device-specific work.

Included:

- KOReader source under `koreader-src/`, with upstream notices preserved.
- Libra 2 reader, file-manager, input, network, Bluetooth, and TTS changes.
- Native C sources and the small CC0 `minimp3` dependency.
- A normalized Linux 4.1.15 kernel source patch and target configuration.
- Build, benchmark, deploy, and host-test scripts.
- License texts and third-party attribution notes.

Excluded intentionally:

- Private device captures, book pages, logs, and reading caches.
- API keys, credentials, SSH material, and workstation-specific paths.
- Prebuilt overlay archives, kernel images, firmware blobs, and build output.
- Nested upstream Git metadata and generated internal-agent context.

The private lab repository remains the historical record for device sessions.
This repository is the reviewable public source surface.
