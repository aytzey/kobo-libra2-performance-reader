#!/usr/bin/env bash

kobo_toolchain_python() {
  if [[ -n "${KOBO_PYTHON:-}" ]]; then
    printf '%s\n' "${KOBO_PYTHON}"
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  elif command -v python >/dev/null 2>&1; then
    command -v python
  else
    echo "Python 3 is required to provision the Kobo toolchain" >&2
    return 1
  fi
}

kobo_toolchain_ensure() {
  local compiler="${KOBO_CC:-}"
  local python

  if [[ -z "${compiler}" ]]; then
    compiler="$(command -v arm-kobov4-linux-gnueabihf-gcc || true)"
  fi
  if [[ -z "${compiler}" ]]; then
    python="$(kobo_toolchain_python)" || return 1
    compiler="$("${python}" "${ROOT}/scripts/bootstrap-kobo-toolchain.py")" || return 1
  fi
  if [[ ! -x "${compiler}" ]]; then
    echo "Kobo ARM compiler is not executable: ${compiler}" >&2
    return 1
  fi

  export KOBO_CC="${compiler}"
  export KOBO_PLAYER_CC="${KOBO_PLAYER_CC:-${compiler}}"
  export KOBO_USB_DHCPD_CC="${KOBO_USB_DHCPD_CC:-${compiler}}"
  export KOBO_STRIP="${KOBO_STRIP:-${compiler%gcc}strip}"
  PATH="$(dirname "${compiler}"):${PATH}"
  export PATH
}
