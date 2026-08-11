# Contributing

Start with a small change and a reproducible check. This project is optimized
for a slow, real e-reader, so host-only intuition is not enough for a device
performance claim.

Include in every performance change:

- target model and firmware;
- baseline and new measurement;
- exact command or fixture;
- power, thermal, and failure impact;
- rollback or restore behavior when system files are touched.

Do not submit books, copyrighted page captures, device logs, Wi-Fi details,
SSH material, API keys, or generated caches. For kernel changes, include the
source base identifier and retain the original Linux copyright and license
notices.

Run the relevant host checks before opening a pull request:

```sh
./scripts/test-libra2-optimize.sh
./scripts/test-overlay-deploy.sh
./scripts/test-ttsreader-helper-host.sh
./scripts/test-ttsreader-player-host.sh
./scripts/test-kobo-toolchain.sh
```
