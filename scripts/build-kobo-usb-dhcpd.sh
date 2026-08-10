#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_CC="$(command -v arm-kobov4-linux-gnueabihf-gcc || command -v arm-linux-gnueabihf-gcc || true)"
CC="${KOBO_USB_DHCPD_CC:-${KOBO_CC:-${DEFAULT_CC}}}"
STRIP="${KOBO_STRIP:-}"
OUT_DIR="${ROOT}/build/kobo/usb-network"
OUT="${OUT_DIR}/kobo-usb-dhcpd"
SRC="${ROOT}/native/kobo-usb-dhcpd.c"

if [[ ! -x "${CC}" ]]; then
  CC="$(command -v arm-kobov4-linux-gnueabihf-gcc || command -v arm-linux-gnueabihf-gcc || true)"
fi
if [[ -z "${CC}" || ! -x "${CC}" ]]; then
  echo "Kobo ARM compiler not found" >&2
  exit 1
fi
if [[ -z "${STRIP}" ]]; then
  STRIP="${CC%gcc}strip"
fi

mkdir -p "${OUT_DIR}"
"${CC}" \
  -std=gnu99 \
  -Os \
  -DNDEBUG \
  -Wall \
  -Wextra \
  -Werror \
  -ffunction-sections \
  -fdata-sections \
  -mcpu=cortex-a9 \
  -mfloat-abi=hard \
  -mfpu=neon \
  -Wl,-O1 \
  -Wl,--as-needed \
  -Wl,--gc-sections \
  -o "${OUT}" \
  "${SRC}"

if command -v "${STRIP}" >/dev/null 2>&1; then
  "${STRIP}" "${OUT}" 2>/dev/null || true
fi

chmod 755 "${OUT}"
printf '%s\n' "${OUT}"
