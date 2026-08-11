#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
TARGET="arm-kobov4-linux-gnueabihf"
ORIGINAL_PATH="${PATH}"
cleanup() {
  chmod -R u+w "${WORK}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

mkdir -p "${WORK}/x-tools/${TARGET}/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"${WORK}/x-tools/${TARGET}/bin/${TARGET}-gcc"
chmod 755 "${WORK}/x-tools/${TARGET}/bin/${TARGET}-gcc"
chmod -R a-w "${WORK}/x-tools"
tar -C "${WORK}" -czf "${WORK}/kobov4.tar.gz" x-tools
SHA256="$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "${WORK}/kobov4.tar.gz")"

unset KOBO_CC KOBO_PLAYER_CC KOBO_USB_DHCPD_CC KOBO_STRIP
export KOBO_TOOLCHAIN_CACHE="${WORK}/cache"
export KOBO_TOOLCHAIN_URL="file://${WORK}/kobov4.tar.gz"
export KOBO_TOOLCHAIN_SHA256="${SHA256}"
source "${ROOT}/scripts/kobo-toolchain.sh"
kobo_toolchain_ensure

EXPECTED="${WORK}/cache/koxtoolchain-2025.05/${TARGET}/bin/${TARGET}-gcc"
[[ "${KOBO_CC}" == "${EXPECTED}" ]]
[[ -x "${KOBO_CC}" ]]

if (
  PATH="${ORIGINAL_PATH}"
  unset KOBO_CC KOBO_PLAYER_CC KOBO_USB_DHCPD_CC KOBO_STRIP
  export KOBO_TOOLCHAIN_CACHE="${WORK}/disabled"
  export KOBO_TOOLCHAIN_AUTO_FETCH=0
  source "${ROOT}/scripts/kobo-toolchain.sh"
  kobo_toolchain_ensure
); then
  echo "expected auto-fetch opt-out to fail" >&2
  exit 1
fi

if (
  PATH="${ORIGINAL_PATH}"
  unset KOBO_CC KOBO_PLAYER_CC KOBO_USB_DHCPD_CC KOBO_STRIP
  export KOBO_TOOLCHAIN_CACHE="${WORK}/bad-hash"
  export KOBO_TOOLCHAIN_ARCHIVE="${WORK}/kobov4.tar.gz"
  export KOBO_TOOLCHAIN_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  source "${ROOT}/scripts/kobo-toolchain.sh"
  kobo_toolchain_ensure
); then
  echo "expected checksum mismatch to fail" >&2
  exit 1
fi
[[ -f "${WORK}/kobov4.tar.gz" ]]

echo "kobo toolchain bootstrap test passed"
