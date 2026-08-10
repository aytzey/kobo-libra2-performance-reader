#!/usr/bin/env bash

# Libra 2 is a Mk.7+ Kobo device on FW 4.x, matching KOReader's kobov4
# target and NiLuJe's glibc 2.19 sysroot. Keep override support for older
# devices or emergency compatibility checks.
KOBO_NATIVE_MAX_GLIBC="${KOBO_NATIVE_MAX_GLIBC:-GLIBC_2.19}"
KOBO_NATIVE_MACHINE_PATTERN="${KOBO_NATIVE_MACHINE_PATTERN:-ARM}"

kobo_native_machine() {
  local path="$1"
  readelf -h "${path}" 2>/dev/null \
    | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' \
    | head -1
}

kobo_native_is_elf() {
  local path="$1"
  readelf -h "${path}" >/dev/null 2>&1
}

kobo_native_max_glibc() {
  local path="$1"
  readelf --version-info "${path}" 2>/dev/null \
    | grep -Eo 'GLIBC_[0-9]+\.[0-9]+' \
    | sort -Vu \
    | tail -1 || true
}

kobo_native_version_le() {
  local got="$1"
  local max="$2"
  local highest

  if [[ -z "${got}" ]]; then
    return 0
  fi

  highest="$(printf '%s\n%s\n' "${got}" "${max}" | sort -Vu | tail -1)"
  [[ "${highest}" == "${max}" ]]
}

kobo_native_is_abi_compatible() {
  local path="$1"
  local machine
  local max_glibc

  if ! kobo_native_is_elf "${path}"; then
    return 1
  fi

  if [[ "${KOBO_ALLOW_INCOMPATIBLE_NATIVE:-0}" == "1" ]]; then
    return 0
  fi

  machine="$(kobo_native_machine "${path}")"
  if [[ "${machine}" != *"${KOBO_NATIVE_MACHINE_PATTERN}"* ]]; then
    return 1
  fi

  max_glibc="$(kobo_native_max_glibc "${path}")"
  kobo_native_version_le "${max_glibc}" "${KOBO_NATIVE_MAX_GLIBC}"
}

kobo_native_find_build_lib() {
  local src="$1"
  local libname="$2"
  local candidate
  local candidates=()

  while IFS= read -r candidate; do
    candidates+=("${candidate}")
  done < <(find "${src}/base/build" -path "*/libs/${libname}" ! -path '*x86_64*' -type f 2>/dev/null | sort)

  for candidate in "${candidates[@]}"; do
    if [[ "${candidate}" == *"/arm-kobov4-linux-gnueabihf/"* ]] && kobo_native_is_abi_compatible "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  for candidate in "${candidates[@]}"; do
    if [[ "${candidate}" == *"/arm-kobo-linux-gnueabihf/"* ]] && kobo_native_is_abi_compatible "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  for candidate in "${candidates[@]}"; do
    if [[ "${candidate}" == *"/arm-kobov5-linux-gnueabihf/"* ]] && kobo_native_is_abi_compatible "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  for candidate in "${candidates[@]}"; do
    if kobo_native_is_abi_compatible "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  if ((${#candidates[@]} > 0)); then
    printf '%s\n' "${candidates[$((${#candidates[@]} - 1))]}"
  fi
}

kobo_native_find_compatible_backup_lib() {
  local root="$1"
  local libname="$2"
  local backup
  local path

  if [[ ! -d "${root}/backups" ]]; then
    return 0
  fi

  while IFS= read -r backup; do
    path="${backup}/.adds/koreader/libs/${libname}"
    if [[ -f "${path}" ]] && kobo_native_is_abi_compatible "${path}"; then
      printf '%s\n' "${path}"
      return 0
    fi
  done < <(find "${root}/backups" -mindepth 1 -maxdepth 1 -type d | sort -r)
}

kobo_native_glibc_label() {
  local path="$1"
  local max_glibc

  if ! kobo_native_is_elf "${path}"; then
    printf 'not an ELF shared object\n'
    return 0
  fi

  max_glibc="$(kobo_native_max_glibc "${path}")"
  if [[ -n "${max_glibc}" ]]; then
    printf '%s\n' "${max_glibc}"
  else
    printf 'no GLIBC version tags\n'
  fi
}

kobo_native_copy_lib() {
  local root="$1"
  local src="$2"
  local candidate="$3"
  local libname="$4"
  local label="$5"
  local dest="$6"
  local missing_message="$7"
  local fallback

  if [[ -z "${candidate}" ]]; then
    candidate="$(kobo_native_find_build_lib "${src}" "${libname}")"
  fi

  if [[ -n "${candidate}" && -f "${candidate}" ]]; then
    if kobo_native_is_abi_compatible "${candidate}"; then
      cp "${candidate}" "${dest}/${libname}"
      return 0
    fi

    echo "warning: ${candidate} requires $(kobo_native_glibc_label "${candidate}"), newer than ${KOBO_NATIVE_MAX_GLIBC}; not using it for Kobo" >&2
  fi

  fallback="$(kobo_native_find_compatible_backup_lib "${root}" "${libname}")"
  if [[ -n "${fallback}" ]]; then
    echo "warning: using Kobo-compatible backup ${libname}: ${fallback}" >&2
    cp "${fallback}" "${dest}/${libname}"
    return 0
  fi

  echo "warning: Kobo-compatible ${libname} not found for ${label}; ${missing_message}" >&2
  return 0
}
