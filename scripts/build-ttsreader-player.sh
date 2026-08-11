#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/kobo-toolchain.sh"
kobo_toolchain_ensure

CC="${KOBO_CC}"
PLAYER_CC="${KOBO_PLAYER_CC}"
OUT_DIR="${ROOT}/build/kobo/ttsreader-player"
OUT="${OUT_DIR}/libttsreader-player.so"
PLAYER_OUT="${OUT_DIR}/ttsreader-play"
SRC="${ROOT}/native/ttsreader-player.c"
PLAYER_SRC="${ROOT}/native/ttsreader-play.c"
ALSA_STUB_DIR="${OUT_DIR}/alsa-sdk"
ALSA_STUB="${ALSA_STUB_DIR}/libasound.so"
ALSA_STUB_SRC="${ROOT}/native/alsa-link-stub.c"
STRIP="${KOBO_STRIP}"

mkdir -p "${OUT_DIR}" "${ALSA_STUB_DIR}"

"${CC}" \
  -std=gnu99 \
  -shared \
  -fPIC \
  -O3 \
  -fvisibility=hidden \
  -Wall \
  -Wextra \
  -Werror \
  -mcpu=cortex-a9 \
  -mfloat-abi=hard \
  -mfpu=neon \
  -Wl,-O1 \
  -Wl,--as-needed \
  -Wl,--gc-sections \
  -Wl,-soname,libttsreader-player.so \
  -o "${OUT}" \
  "${SRC}"

"${PLAYER_CC}" \
  -std=gnu99 \
  -shared \
  -fPIC \
  -Wall \
  -Wextra \
  -Werror \
  -Wl,-soname,libasound.so.2 \
  -o "${ALSA_STUB}" \
  "${ALSA_STUB_SRC}"

"${PLAYER_CC}" \
  -std=gnu99 \
  -O3 \
  -DNDEBUG \
  -Wall \
  -Wextra \
  -Werror \
  -mcpu=cortex-a9 \
  -mfloat-abi=hard \
  -mfpu=neon \
  -I"${ROOT}/third_party/minimp3" \
  -I"${ROOT}/native" \
  -L"${ALSA_STUB_DIR}" \
  -Wl,-O1 \
  -Wl,--as-needed \
  -Wl,--gc-sections \
  -Wl,--no-as-needed \
  -o "${PLAYER_OUT}" \
  "${PLAYER_SRC}" \
  -lasound \
  -Wl,--as-needed \
  -lm

if command -v "${STRIP}" >/dev/null 2>&1; then
  "${STRIP}" "${OUT}" "${PLAYER_OUT}" 2>/dev/null || true
fi

chmod 755 "${PLAYER_OUT}"
printf '%s\n' "${OUT}"
