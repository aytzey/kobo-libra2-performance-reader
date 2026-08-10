#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PLAYER_CC="$(command -v arm-linux-gnueabihf-gcc || true)"
CC="${KOBO_CC:-${DEFAULT_PLAYER_CC}}"
PLAYER_CC="${KOBO_PLAYER_CC:-${DEFAULT_PLAYER_CC}}"
OUT_DIR="${ROOT}/build/kobo/ttsreader-player"
OUT="${OUT_DIR}/libttsreader-player.so"
PLAYER_OUT="${OUT_DIR}/ttsreader-play"
SRC="${ROOT}/native/ttsreader-player.c"
PLAYER_SRC="${ROOT}/native/ttsreader-play.c"
STRIP="${KOBO_STRIP:-arm-linux-gnueabihf-strip}"

mkdir -p "${OUT_DIR}"

if [[ -z "${CC}" || ! -x "${CC}" ]]; then
  echo "Kobo ARM compiler not found; set KOBO_CC to the compiler path" >&2
  exit 1
fi

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

if [[ ! -x "${PLAYER_CC}" ]]; then
  PLAYER_CC="${CC}"
fi

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
  -Wl,-O1 \
  -Wl,--as-needed \
  -Wl,--gc-sections \
  -o "${PLAYER_OUT}" \
  "${PLAYER_SRC}" \
  -lasound \
  -lm

if command -v "${STRIP}" >/dev/null 2>&1; then
  "${STRIP}" "${OUT}" "${PLAYER_OUT}" 2>/dev/null || true
fi

chmod 755 "${PLAYER_OUT}"
printf '%s\n' "${OUT}"
