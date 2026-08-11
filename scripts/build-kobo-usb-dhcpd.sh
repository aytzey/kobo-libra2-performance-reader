#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/kobo-toolchain.sh"
kobo_toolchain_ensure

CC="${KOBO_USB_DHCPD_CC}"
STRIP="${KOBO_STRIP}"
OUT_DIR="${ROOT}/build/kobo/usb-network"
OUT="${OUT_DIR}/kobo-usb-dhcpd"
SRC="${ROOT}/native/kobo-usb-dhcpd.c"

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
