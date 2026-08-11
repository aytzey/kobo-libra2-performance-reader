#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/koreader-src"
DIST="${ROOT}/dist"
STAGE="$(mktemp -d)"
OUT="${DIST}/koreader-libra2-optimized-overlay.zip"
TTSREADER_PLAYER_SO="${KOBO_LIBTTSREADER_PLAYER_SO:-}"
TTSREADER_PLAYER_BIN="${KOBO_TTSREADER_PLAYER_BIN:-}"
USB_DHCPD_BIN="${KOBO_USB_DHCPD_BIN:-}"
SKIP_NATIVE="${KOBO_SKIP_NATIVE:-0}"

source "${ROOT}/scripts/kobo-native-abi.sh"
source "${ROOT}/scripts/kobo-toolchain.sh"

cleanup() {
  rm -rf "${STAGE}"
}
trap cleanup EXIT

preserve_packaged_lib() {
  local libname="$1"
  local zip_path=".adds/koreader/libs/${libname}"
  local dst="${STAGE}/${zip_path}"
  local tmp

  if [[ -f "${dst}" || ! -f "${OUT}" ]]; then
    return 0
  fi

  if unzip -Z1 "${OUT}" "${zip_path}" >/dev/null 2>&1; then
    tmp="${STAGE}/.${libname}.preserve"
    unzip -p "${OUT}" "${zip_path}" >"${tmp}"
    if kobo_native_is_abi_compatible "${tmp}"; then
      mv "${tmp}" "${dst}"
      chmod 755 "${dst}"
      echo "warning: preserved packaged ${libname} from existing overlay" >&2
    else
      rm -f "${tmp}"
      echo "warning: existing packaged ${libname} is not Kobo-compatible; not preserving it" >&2
    fi
  fi
}

mkdir -p "${DIST}"
if [[ "${SKIP_NATIVE}" != "1" ]]; then
  kobo_toolchain_ensure
  if [[ -z "${TTSREADER_PLAYER_SO}" && -x "${ROOT}/scripts/build-ttsreader-player.sh" ]]; then
    TTSREADER_PLAYER_SO="$("${ROOT}/scripts/build-ttsreader-player.sh")"
  fi
  if [[ -z "${TTSREADER_PLAYER_BIN}" && -x "${ROOT}/build/kobo/ttsreader-player/ttsreader-play" ]]; then
    TTSREADER_PLAYER_BIN="${ROOT}/build/kobo/ttsreader-player/ttsreader-play"
  fi
  if [[ -z "${USB_DHCPD_BIN}" && -x "${ROOT}/scripts/build-kobo-usb-dhcpd.sh" ]]; then
    USB_DHCPD_BIN="$("${ROOT}/scripts/build-kobo-usb-dhcpd.sh")"
  fi
  if [[ -z "${USB_DHCPD_BIN}" && -x "${ROOT}/build/kobo/usb-network/kobo-usb-dhcpd" ]]; then
    USB_DHCPD_BIN="${ROOT}/build/kobo/usb-network/kobo-usb-dhcpd"
  fi
fi

mkdir -p "${STAGE}/.adds/koreader/bin"
mkdir -p "${STAGE}/.adds/koreader/ffi"
mkdir -p "${STAGE}/.adds/koreader/libs"
mkdir -p "${STAGE}/.adds/koreader/frontend/apps/filemanager"
mkdir -p "${STAGE}/.adds/koreader/frontend/apps/reader/modules"
mkdir -p "${STAGE}/.adds/koreader/frontend/device"
mkdir -p "${STAGE}/.adds/koreader/frontend/device/kobo"
mkdir -p "${STAGE}/.adds/koreader/frontend/document"
mkdir -p "${STAGE}/.adds/koreader/frontend/ui/elements"
mkdir -p "${STAGE}/.adds/koreader/frontend/ui/network"
mkdir -p "${STAGE}/.adds/koreader/frontend/ui/widget"
mkdir -p "${STAGE}/.adds/koreader/frontend/ui/widget/container"
mkdir -p "${STAGE}/.adds/koreader/plugins"
mkdir -p "${STAGE}/.adds/koreader/plugins/SSH.koplugin"

cp "${SRC}/defaults.lua" "${STAGE}/.adds/koreader/defaults.lua"
cp "${SRC}/base/ffi/blitbuffer.lua" "${STAGE}/.adds/koreader/ffi/blitbuffer.lua"
cp "${SRC}/base/ffi/mupdf.lua" "${STAGE}/.adds/koreader/ffi/mupdf.lua"
cp "${SRC}/base/ffi/xxhash.lua" "${STAGE}/.adds/koreader/ffi/xxhash.lua"
cp "${SRC}/base/ffi/xxhash_h.lua" "${STAGE}/.adds/koreader/ffi/xxhash_h.lua"
cp "${SRC}/frontend/cache.lua" "${STAGE}/.adds/koreader/frontend/cache.lua"
cp "${SRC}/frontend/dispatcher.lua" "${STAGE}/.adds/koreader/frontend/dispatcher.lua"
cp "${SRC}/frontend/pluginloader.lua" "${STAGE}/.adds/koreader/frontend/pluginloader.lua"
cp "${SRC}/frontend/device/input.lua" "${STAGE}/.adds/koreader/frontend/device/input.lua"
cp "${SRC}/frontend/device/gesturedetector.lua" "${STAGE}/.adds/koreader/frontend/device/gesturedetector.lua"
cp "${SRC}/frontend/device/kobo/device.lua" "${STAGE}/.adds/koreader/frontend/device/kobo/device.lua"
cp "${SRC}/frontend/apps/filemanager/filemanager.lua" "${STAGE}/.adds/koreader/frontend/apps/filemanager/filemanager.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagerbookinfo.lua" "${STAGE}/.adds/koreader/frontend/apps/filemanager/filemanagerbookinfo.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagercollection.lua" "${STAGE}/.adds/koreader/frontend/apps/filemanager/filemanagercollection.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagerfilesearcher.lua" "${STAGE}/.adds/koreader/frontend/apps/filemanager/filemanagerfilesearcher.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagerhistory.lua" "${STAGE}/.adds/koreader/frontend/apps/filemanager/filemanagerhistory.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagermenu.lua" "${STAGE}/.adds/koreader/frontend/apps/filemanager/filemanagermenu.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagershortcuts.lua" "${STAGE}/.adds/koreader/frontend/apps/filemanager/filemanagershortcuts.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagerutil.lua" "${STAGE}/.adds/koreader/frontend/apps/filemanager/filemanagerutil.lua"
cp "${SRC}/frontend/apps/reader/readerui.lua" "${STAGE}/.adds/koreader/frontend/apps/reader/readerui.lua"
cp "${SRC}/frontend/apps/reader/modules/readerfooter.lua" "${STAGE}/.adds/koreader/frontend/apps/reader/modules/readerfooter.lua"
cp "${SRC}/frontend/apps/reader/modules/readerhighlight.lua" "${STAGE}/.adds/koreader/frontend/apps/reader/modules/readerhighlight.lua"
cp "${SRC}/frontend/apps/reader/modules/readerkoptlistener.lua" "${STAGE}/.adds/koreader/frontend/apps/reader/modules/readerkoptlistener.lua"
cp "${SRC}/frontend/apps/reader/modules/readermenu.lua" "${STAGE}/.adds/koreader/frontend/apps/reader/modules/readermenu.lua"
cp "${SRC}/frontend/apps/reader/modules/readerview.lua" "${STAGE}/.adds/koreader/frontend/apps/reader/modules/readerview.lua"
cp "${SRC}/frontend/apps/reader/modules/readerzooming.lua" "${STAGE}/.adds/koreader/frontend/apps/reader/modules/readerzooming.lua"
cp "${SRC}/frontend/apps/reader/modules/readerrolling.lua" "${STAGE}/.adds/koreader/frontend/apps/reader/modules/readerrolling.lua"
cp "${SRC}/frontend/ui/menusorter.lua" "${STAGE}/.adds/koreader/frontend/ui/menusorter.lua"
cp "${SRC}/frontend/ui/uimanager.lua" "${STAGE}/.adds/koreader/frontend/ui/uimanager.lua"
cp "${SRC}/frontend/ui/network/manager.lua" "${STAGE}/.adds/koreader/frontend/ui/network/manager.lua"
cp "${SRC}/frontend/ui/network/wpa_supplicant.lua" "${STAGE}/.adds/koreader/frontend/ui/network/wpa_supplicant.lua"
cp "${SRC}/frontend/document/credocument.lua" "${STAGE}/.adds/koreader/frontend/document/credocument.lua"
cp "${SRC}/frontend/document/doccache.lua" "${STAGE}/.adds/koreader/frontend/document/doccache.lua"
cp "${SRC}/frontend/document/document.lua" "${STAGE}/.adds/koreader/frontend/document/document.lua"
cp "${SRC}/frontend/document/documentregistry.lua" "${STAGE}/.adds/koreader/frontend/document/documentregistry.lua"
cp "${SRC}/frontend/document/koptinterface.lua" "${STAGE}/.adds/koreader/frontend/document/koptinterface.lua"
cp "${SRC}/frontend/ui/elements/mass_storage.lua" "${STAGE}/.adds/koreader/frontend/ui/elements/mass_storage.lua"
cp "${SRC}/frontend/ui/elements/reader_menu_order.lua" "${STAGE}/.adds/koreader/frontend/ui/elements/reader_menu_order.lua"
cp "${SRC}/frontend/ui/elements/filemanager_menu_order.lua" "${STAGE}/.adds/koreader/frontend/ui/elements/filemanager_menu_order.lua"
cp "${SRC}/frontend/ui/widget/eventlistener.lua" "${STAGE}/.adds/koreader/frontend/ui/widget/eventlistener.lua"
cp "${SRC}/frontend/ui/widget/networksetting.lua" "${STAGE}/.adds/koreader/frontend/ui/widget/networksetting.lua"
cp "${SRC}/frontend/ui/widget/container/inputcontainer.lua" "${STAGE}/.adds/koreader/frontend/ui/widget/container/inputcontainer.lua"
cp "${SRC}/frontend/ui/widget/container/widgetcontainer.lua" "${STAGE}/.adds/koreader/frontend/ui/widget/container/widgetcontainer.lua"
cp "${SRC}/frontend/ui/widget/filechooser.lua" "${STAGE}/.adds/koreader/frontend/ui/widget/filechooser.lua"
cp "${SRC}/platform/kobo/koreader.sh" "${STAGE}/.adds/koreader/koreader.sh"
cp "${SRC}/platform/kobo/enable-wifi.sh" "${STAGE}/.adds/koreader/enable-wifi.sh"
cp "${SRC}/platform/kobo/disable-wifi.sh" "${STAGE}/.adds/koreader/disable-wifi.sh"
cp "${SRC}/platform/kobo/obtain-ip.sh" "${STAGE}/.adds/koreader/obtain-ip.sh"
cp "${SRC}/platform/kobo/release-ip.sh" "${STAGE}/.adds/koreader/release-ip.sh"
cp "${SRC}/platform/kobo/restore-wifi-async.sh" "${STAGE}/.adds/koreader/restore-wifi-async.sh"
cp "${SRC}/platform/kobo/usb-network-ssh.sh" "${STAGE}/.adds/koreader/usb-network-ssh.sh"
cp "${SRC}/platform/kobo/libra2-optimize.sh" "${STAGE}/.adds/koreader/libra2-optimize.sh"
cp "${SRC}/platform/kobo/libra2-preflight.lua" "${STAGE}/.adds/koreader/libra2-preflight.lua"
chmod 755 "${STAGE}/.adds/koreader/"*.sh
cp -a "${SRC}/plugins/libra2perf.koplugin" "${STAGE}/.adds/koreader/plugins/"
cp "${SRC}/plugins/SSH.koplugin/_meta.lua" "${STAGE}/.adds/koreader/plugins/SSH.koplugin/_meta.lua"
cp "${SRC}/plugins/SSH.koplugin/main.lua" "${STAGE}/.adds/koreader/plugins/SSH.koplugin/main.lua"
cp -a "${SRC}/plugins/ttsreader.koplugin" "${STAGE}/.adds/koreader/plugins/"

if [[ -n "${TTSREADER_PLAYER_BIN}" && -x "${TTSREADER_PLAYER_BIN}" ]] && kobo_native_is_abi_compatible "${TTSREADER_PLAYER_BIN}"; then
  cp "${TTSREADER_PLAYER_BIN}" "${STAGE}/.adds/koreader/bin/ttsreader-play"
  chmod 755 "${STAGE}/.adds/koreader/bin/ttsreader-play"
else
  echo "warning: Kobo-compatible ttsreader-play not found; external player fallback remains enabled" >&2
fi

if [[ -n "${USB_DHCPD_BIN}" && -x "${USB_DHCPD_BIN}" ]] && kobo_native_is_abi_compatible "${USB_DHCPD_BIN}"; then
  cp "${USB_DHCPD_BIN}" "${STAGE}/.adds/koreader/bin/kobo-usb-dhcpd"
  chmod 755 "${STAGE}/.adds/koreader/bin/kobo-usb-dhcpd"
else
  echo "warning: Kobo-compatible kobo-usb-dhcpd not found; USB SSH may need static host IP" >&2
fi

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBBLITBUFFER_SO:-}" \
  "libblitbuffer.so" \
  "C blitbuffer" \
  "${STAGE}/.adds/koreader/libs" \
  "will try to preserve an existing overlay copy"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBINPUT_SO:-}" \
  "libkoreader-input.so" \
  "native input event fast paths" \
  "${STAGE}/.adds/koreader/libs" \
  "will try to preserve an existing overlay copy"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBWRAP_MUPDF_SO:-}" \
  "libwrap-mupdf.so" \
  "C MuPDF wrapper" \
  "${STAGE}/.adds/koreader/libs" \
  "will try to preserve an existing overlay copy"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBXXHASH_SO:-}" \
  "libxxhash.so.0" \
  "native xxHash cache hashing" \
  "${STAGE}/.adds/koreader/libs" \
  "will try to preserve an existing overlay copy"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBXTEXT_SO:-}" \
  "libkoreader-xtext.so" \
  "native XText shaping/string fast paths" \
  "${STAGE}/.adds/koreader/libs" \
  "will try to preserve an existing overlay copy"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBCRE_SO:-}" \
  "libkoreader-cre.so" \
  "native CRe EPUB string fast paths" \
  "${STAGE}/.adds/koreader/libs" \
  "will try to preserve an existing overlay copy"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${TTSREADER_PLAYER_SO}" \
  "libttsreader-player.so" \
  "native TTS player process controls" \
  "${STAGE}/.adds/koreader/libs" \
  "will try to preserve an existing overlay copy"

preserve_packaged_lib "libblitbuffer.so"
preserve_packaged_lib "libkoreader-input.so"
preserve_packaged_lib "libwrap-mupdf.so"
preserve_packaged_lib "libxxhash.so.0"
preserve_packaged_lib "libkoreader-xtext.so"
preserve_packaged_lib "libkoreader-cre.so"
preserve_packaged_lib "libttsreader-player.so"

chmod 755 "${STAGE}/.adds/koreader/koreader.sh"
chmod 755 "${STAGE}/.adds/koreader/libra2-optimize.sh"

rm -f "${OUT}"
if command -v zip >/dev/null 2>&1; then
  (cd "${STAGE}" && zip -qr "${OUT}" .)
else
  "$(kobo_toolchain_python)" "${ROOT}/scripts/create-overlay-zip.py" "${STAGE}" "${OUT}"
fi

echo "${OUT}"
