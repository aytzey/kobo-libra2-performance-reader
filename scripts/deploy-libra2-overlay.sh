#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/koreader-src"
MOUNT="${1:-/media/${USER}/KOBOeReader}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${ROOT}/backups/${STAMP}"
KOREADER="${MOUNT}/.adds/koreader"
STAGE="${KOREADER}/.libra2-overlay-stage-${STAMP}"
TTSREADER_PLAYER_SO="${KOBO_LIBTTSREADER_PLAYER_SO:-}"
TTSREADER_PLAYER_BIN="${KOBO_TTSREADER_PLAYER_BIN:-}"
USB_DHCPD_BIN="${KOBO_USB_DHCPD_BIN:-}"

source "${ROOT}/scripts/kobo-native-abi.sh"

cleanup() {
  rm -rf "${STAGE}"
}
trap cleanup EXIT

if [[ ! -d "${KOREADER}" ]]; then
  echo "KOReader not found at ${KOREADER}" >&2
  exit 1
fi

mkdir -p "${STAGE}/frontend/document"
mkdir -p "${STAGE}/frontend"
mkdir -p "${STAGE}/frontend/apps/filemanager"
mkdir -p "${STAGE}/frontend/apps/reader/modules"
mkdir -p "${STAGE}/frontend/device"
mkdir -p "${STAGE}/frontend/device/kobo"
mkdir -p "${STAGE}/frontend/ui/elements"
mkdir -p "${STAGE}/frontend/ui/network"
mkdir -p "${STAGE}/frontend/ui/widget"
mkdir -p "${STAGE}/frontend/ui/widget/container"
mkdir -p "${STAGE}/ffi"
mkdir -p "${STAGE}/bin"
mkdir -p "${STAGE}/libs"
mkdir -p "${STAGE}/plugins"
mkdir -p "${STAGE}/plugins/SSH.koplugin"
if [[ -z "${TTSREADER_PLAYER_SO}" && -x "${ROOT}/scripts/build-ttsreader-player.sh" ]]; then
  TTSREADER_PLAYER_SO="$("${ROOT}/scripts/build-ttsreader-player.sh" 2>/dev/null || true)"
fi
if [[ -z "${TTSREADER_PLAYER_BIN}" && -x "${ROOT}/build/kobo/ttsreader-player/ttsreader-play" ]]; then
  TTSREADER_PLAYER_BIN="${ROOT}/build/kobo/ttsreader-player/ttsreader-play"
fi
if [[ -z "${USB_DHCPD_BIN}" && -x "${ROOT}/scripts/build-kobo-usb-dhcpd.sh" ]]; then
  USB_DHCPD_BIN="$("${ROOT}/scripts/build-kobo-usb-dhcpd.sh" 2>/dev/null || true)"
fi
if [[ -z "${USB_DHCPD_BIN}" && -x "${ROOT}/build/kobo/usb-network/kobo-usb-dhcpd" ]]; then
  USB_DHCPD_BIN="${ROOT}/build/kobo/usb-network/kobo-usb-dhcpd"
fi

cp "${SRC}/defaults.lua" "${STAGE}/defaults.lua"
cp "${SRC}/base/ffi/blitbuffer.lua" "${STAGE}/ffi/blitbuffer.lua"
cp "${SRC}/base/ffi/mupdf.lua" "${STAGE}/ffi/mupdf.lua"
cp "${SRC}/base/ffi/xxhash.lua" "${STAGE}/ffi/xxhash.lua"
cp "${SRC}/base/ffi/xxhash_h.lua" "${STAGE}/ffi/xxhash_h.lua"
cp "${SRC}/frontend/cache.lua" "${STAGE}/frontend/cache.lua"
cp "${SRC}/frontend/dispatcher.lua" "${STAGE}/frontend/dispatcher.lua"
cp "${SRC}/frontend/pluginloader.lua" "${STAGE}/frontend/pluginloader.lua"
cp "${SRC}/frontend/device/input.lua" "${STAGE}/frontend/device/input.lua"
cp "${SRC}/frontend/device/gesturedetector.lua" "${STAGE}/frontend/device/gesturedetector.lua"
cp "${SRC}/frontend/device/kobo/device.lua" "${STAGE}/frontend/device/kobo/device.lua"
cp "${SRC}/frontend/apps/filemanager/filemanager.lua" "${STAGE}/frontend/apps/filemanager/filemanager.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagerbookinfo.lua" "${STAGE}/frontend/apps/filemanager/filemanagerbookinfo.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagercollection.lua" "${STAGE}/frontend/apps/filemanager/filemanagercollection.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagerfilesearcher.lua" "${STAGE}/frontend/apps/filemanager/filemanagerfilesearcher.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagerhistory.lua" "${STAGE}/frontend/apps/filemanager/filemanagerhistory.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagermenu.lua" "${STAGE}/frontend/apps/filemanager/filemanagermenu.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagershortcuts.lua" "${STAGE}/frontend/apps/filemanager/filemanagershortcuts.lua"
cp "${SRC}/frontend/apps/filemanager/filemanagerutil.lua" "${STAGE}/frontend/apps/filemanager/filemanagerutil.lua"
cp "${SRC}/frontend/apps/reader/readerui.lua" "${STAGE}/frontend/apps/reader/readerui.lua"
cp "${SRC}/frontend/apps/reader/modules/readerfooter.lua" "${STAGE}/frontend/apps/reader/modules/readerfooter.lua"
cp "${SRC}/frontend/apps/reader/modules/readerhighlight.lua" "${STAGE}/frontend/apps/reader/modules/readerhighlight.lua"
cp "${SRC}/frontend/apps/reader/modules/readerkoptlistener.lua" "${STAGE}/frontend/apps/reader/modules/readerkoptlistener.lua"
cp "${SRC}/frontend/apps/reader/modules/readermenu.lua" "${STAGE}/frontend/apps/reader/modules/readermenu.lua"
cp "${SRC}/frontend/apps/reader/modules/readerview.lua" "${STAGE}/frontend/apps/reader/modules/readerview.lua"
cp "${SRC}/frontend/apps/reader/modules/readerzooming.lua" "${STAGE}/frontend/apps/reader/modules/readerzooming.lua"
cp "${SRC}/frontend/apps/reader/modules/readerrolling.lua" "${STAGE}/frontend/apps/reader/modules/readerrolling.lua"
cp "${SRC}/frontend/ui/menusorter.lua" "${STAGE}/frontend/ui/menusorter.lua"
cp "${SRC}/frontend/ui/uimanager.lua" "${STAGE}/frontend/ui/uimanager.lua"
cp "${SRC}/frontend/ui/network/manager.lua" "${STAGE}/frontend/ui/network/manager.lua"
cp "${SRC}/frontend/ui/network/wpa_supplicant.lua" "${STAGE}/frontend/ui/network/wpa_supplicant.lua"
cp "${SRC}/frontend/document/credocument.lua" "${STAGE}/frontend/document/credocument.lua"
cp "${SRC}/frontend/document/doccache.lua" "${STAGE}/frontend/document/doccache.lua"
cp "${SRC}/frontend/document/document.lua" "${STAGE}/frontend/document/document.lua"
cp "${SRC}/frontend/document/documentregistry.lua" "${STAGE}/frontend/document/documentregistry.lua"
cp "${SRC}/frontend/document/koptinterface.lua" "${STAGE}/frontend/document/koptinterface.lua"
cp "${SRC}/frontend/ui/elements/mass_storage.lua" "${STAGE}/frontend/ui/elements/mass_storage.lua"
cp "${SRC}/frontend/ui/elements/reader_menu_order.lua" "${STAGE}/frontend/ui/elements/reader_menu_order.lua"
cp "${SRC}/frontend/ui/elements/filemanager_menu_order.lua" "${STAGE}/frontend/ui/elements/filemanager_menu_order.lua"
cp "${SRC}/frontend/ui/widget/eventlistener.lua" "${STAGE}/frontend/ui/widget/eventlistener.lua"
cp "${SRC}/frontend/ui/widget/networksetting.lua" "${STAGE}/frontend/ui/widget/networksetting.lua"
cp "${SRC}/frontend/ui/widget/container/inputcontainer.lua" "${STAGE}/frontend/ui/widget/container/inputcontainer.lua"
cp "${SRC}/frontend/ui/widget/container/widgetcontainer.lua" "${STAGE}/frontend/ui/widget/container/widgetcontainer.lua"
cp "${SRC}/frontend/ui/widget/filechooser.lua" "${STAGE}/frontend/ui/widget/filechooser.lua"
cp "${SRC}/platform/kobo/koreader.sh" "${STAGE}/koreader.sh"
cp "${SRC}/platform/kobo/enable-wifi.sh" "${STAGE}/enable-wifi.sh"
cp "${SRC}/platform/kobo/disable-wifi.sh" "${STAGE}/disable-wifi.sh"
cp "${SRC}/platform/kobo/obtain-ip.sh" "${STAGE}/obtain-ip.sh"
cp "${SRC}/platform/kobo/release-ip.sh" "${STAGE}/release-ip.sh"
cp "${SRC}/platform/kobo/restore-wifi-async.sh" "${STAGE}/restore-wifi-async.sh"
cp "${SRC}/platform/kobo/usb-network-ssh.sh" "${STAGE}/usb-network-ssh.sh"
cp "${SRC}/platform/kobo/libra2-optimize.sh" "${STAGE}/libra2-optimize.sh"
cp "${SRC}/platform/kobo/libra2-preflight.lua" "${STAGE}/libra2-preflight.lua"
chmod 755 "${STAGE}/"*.sh
cp -a "${SRC}/plugins/libra2perf.koplugin" "${STAGE}/plugins/"
cp "${SRC}/plugins/SSH.koplugin/_meta.lua" "${STAGE}/plugins/SSH.koplugin/_meta.lua"
cp "${SRC}/plugins/SSH.koplugin/main.lua" "${STAGE}/plugins/SSH.koplugin/main.lua"
cp -a "${SRC}/plugins/ttsreader.koplugin" "${STAGE}/plugins/"

if [[ -n "${TTSREADER_PLAYER_BIN}" && -x "${TTSREADER_PLAYER_BIN}" ]] && kobo_native_is_abi_compatible "${TTSREADER_PLAYER_BIN}"; then
  cp "${TTSREADER_PLAYER_BIN}" "${STAGE}/bin/ttsreader-play"
  chmod 755 "${STAGE}/bin/ttsreader-play"
else
  echo "warning: Kobo-compatible ttsreader-play not found; external player fallback remains enabled" >&2
fi

if [[ -n "${USB_DHCPD_BIN}" && -x "${USB_DHCPD_BIN}" ]] && kobo_native_is_abi_compatible "${USB_DHCPD_BIN}"; then
  cp "${USB_DHCPD_BIN}" "${STAGE}/bin/kobo-usb-dhcpd"
  chmod 755 "${STAGE}/bin/kobo-usb-dhcpd"
else
  echo "warning: Kobo-compatible kobo-usb-dhcpd not found; USB SSH may need static host IP" >&2
fi

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBBLITBUFFER_SO:-}" \
  "libblitbuffer.so" \
  "C blitbuffer" \
  "${STAGE}/libs" \
  "C blitbuffer changes are not deployed"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBINPUT_SO:-}" \
  "libkoreader-input.so" \
  "native input event fast paths" \
  "${STAGE}/libs" \
  "native input changes are not deployed"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBWRAP_MUPDF_SO:-}" \
  "libwrap-mupdf.so" \
  "C MuPDF wrapper" \
  "${STAGE}/libs" \
  "C MuPDF wrapper changes are not deployed"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBXXHASH_SO:-}" \
  "libxxhash.so.0" \
  "native xxHash cache hashing" \
  "${STAGE}/libs" \
  "native xxHash cache hashing is not deployed"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBXTEXT_SO:-}" \
  "libkoreader-xtext.so" \
  "native XText shaping/string fast paths" \
  "${STAGE}/libs" \
  "native XText changes are not deployed"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${KOBO_LIBCRE_SO:-}" \
  "libkoreader-cre.so" \
  "native CRe EPUB string fast paths" \
  "${STAGE}/libs" \
  "native CRe changes are not deployed"

kobo_native_copy_lib \
  "${ROOT}" \
  "${SRC}" \
  "${TTSREADER_PLAYER_SO}" \
  "libttsreader-player.so" \
  "native TTS player process controls" \
  "${STAGE}/libs" \
  "native TTS player controls are not deployed"

chmod 755 "${STAGE}/koreader.sh"
chmod 755 "${STAGE}/enable-wifi.sh" "${STAGE}/disable-wifi.sh" "${STAGE}/obtain-ip.sh" "${STAGE}/release-ip.sh" "${STAGE}/restore-wifi-async.sh" "${STAGE}/usb-network-ssh.sh"
chmod 755 "${STAGE}/libra2-optimize.sh"

mkdir -p "${BACKUP}/.adds/koreader/frontend/document"
mkdir -p "${BACKUP}/.adds/koreader/frontend"
mkdir -p "${BACKUP}/.adds/koreader/frontend/apps/filemanager"
mkdir -p "${BACKUP}/.adds/koreader/frontend/apps/reader/modules"
mkdir -p "${BACKUP}/.adds/koreader/frontend/device"
mkdir -p "${BACKUP}/.adds/koreader/frontend/device/kobo"
mkdir -p "${BACKUP}/.adds/koreader/frontend/ui/elements"
mkdir -p "${BACKUP}/.adds/koreader/frontend/ui/network"
mkdir -p "${BACKUP}/.adds/koreader/frontend/ui/widget"
mkdir -p "${BACKUP}/.adds/koreader/frontend/ui/widget/container"
mkdir -p "${BACKUP}/.adds/koreader/ffi"
mkdir -p "${BACKUP}/.adds/koreader/bin"
mkdir -p "${BACKUP}/.adds/koreader/libs"
mkdir -p "${BACKUP}/.adds/koreader/plugins"

for file in defaults.lua koreader.sh enable-wifi.sh disable-wifi.sh obtain-ip.sh release-ip.sh restore-wifi-async.sh usb-network-ssh.sh libra2-optimize.sh libra2-preflight.lua; do
  if [[ -e "${KOREADER}/${file}" ]]; then
    cp -a "${KOREADER}/${file}" "${BACKUP}/.adds/koreader/${file}"
  fi
done

if [[ -e "${KOREADER}/frontend/document/koptinterface.lua" ]]; then
  cp -a "${KOREADER}/frontend/document/koptinterface.lua" "${BACKUP}/.adds/koreader/frontend/document/koptinterface.lua"
fi

if [[ -e "${KOREADER}/frontend/document/documentregistry.lua" ]]; then
  cp -a "${KOREADER}/frontend/document/documentregistry.lua" "${BACKUP}/.adds/koreader/frontend/document/documentregistry.lua"
fi

if [[ -e "${KOREADER}/frontend/document/document.lua" ]]; then
  cp -a "${KOREADER}/frontend/document/document.lua" "${BACKUP}/.adds/koreader/frontend/document/document.lua"
fi

if [[ -e "${KOREADER}/frontend/pluginloader.lua" ]]; then
  cp -a "${KOREADER}/frontend/pluginloader.lua" "${BACKUP}/.adds/koreader/frontend/pluginloader.lua"
fi

if [[ -e "${KOREADER}/frontend/dispatcher.lua" ]]; then
  cp -a "${KOREADER}/frontend/dispatcher.lua" "${BACKUP}/.adds/koreader/frontend/dispatcher.lua"
fi

if [[ -e "${KOREADER}/frontend/device/input.lua" ]]; then
  cp -a "${KOREADER}/frontend/device/input.lua" "${BACKUP}/.adds/koreader/frontend/device/input.lua"
fi

if [[ -e "${KOREADER}/frontend/device/gesturedetector.lua" ]]; then
  cp -a "${KOREADER}/frontend/device/gesturedetector.lua" "${BACKUP}/.adds/koreader/frontend/device/gesturedetector.lua"
fi

if [[ -e "${KOREADER}/frontend/device/kobo/device.lua" ]]; then
  cp -a "${KOREADER}/frontend/device/kobo/device.lua" "${BACKUP}/.adds/koreader/frontend/device/kobo/device.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/filemanager/filemanager.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/filemanager/filemanager.lua" "${BACKUP}/.adds/koreader/frontend/apps/filemanager/filemanager.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/filemanager/filemanagerbookinfo.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/filemanager/filemanagerbookinfo.lua" "${BACKUP}/.adds/koreader/frontend/apps/filemanager/filemanagerbookinfo.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/filemanager/filemanagercollection.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/filemanager/filemanagercollection.lua" "${BACKUP}/.adds/koreader/frontend/apps/filemanager/filemanagercollection.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/filemanager/filemanagerfilesearcher.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/filemanager/filemanagerfilesearcher.lua" "${BACKUP}/.adds/koreader/frontend/apps/filemanager/filemanagerfilesearcher.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/filemanager/filemanagerhistory.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/filemanager/filemanagerhistory.lua" "${BACKUP}/.adds/koreader/frontend/apps/filemanager/filemanagerhistory.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/filemanager/filemanagermenu.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/filemanager/filemanagermenu.lua" "${BACKUP}/.adds/koreader/frontend/apps/filemanager/filemanagermenu.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/filemanager/filemanagershortcuts.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/filemanager/filemanagershortcuts.lua" "${BACKUP}/.adds/koreader/frontend/apps/filemanager/filemanagershortcuts.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/filemanager/filemanagerutil.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/filemanager/filemanagerutil.lua" "${BACKUP}/.adds/koreader/frontend/apps/filemanager/filemanagerutil.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/reader/readerui.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/reader/readerui.lua" "${BACKUP}/.adds/koreader/frontend/apps/reader/readerui.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/reader/modules/readerfooter.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/reader/modules/readerfooter.lua" "${BACKUP}/.adds/koreader/frontend/apps/reader/modules/readerfooter.lua"
fi

if [[ -e "${KOREADER}/ffi/blitbuffer.lua" ]]; then
  cp -a "${KOREADER}/ffi/blitbuffer.lua" "${BACKUP}/.adds/koreader/ffi/blitbuffer.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/reader/modules/readerhighlight.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/reader/modules/readerhighlight.lua" "${BACKUP}/.adds/koreader/frontend/apps/reader/modules/readerhighlight.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/reader/modules/readerkoptlistener.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/reader/modules/readerkoptlistener.lua" "${BACKUP}/.adds/koreader/frontend/apps/reader/modules/readerkoptlistener.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/reader/modules/readermenu.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/reader/modules/readermenu.lua" "${BACKUP}/.adds/koreader/frontend/apps/reader/modules/readermenu.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/reader/modules/readerview.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/reader/modules/readerview.lua" "${BACKUP}/.adds/koreader/frontend/apps/reader/modules/readerview.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/reader/modules/readerzooming.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/reader/modules/readerzooming.lua" "${BACKUP}/.adds/koreader/frontend/apps/reader/modules/readerzooming.lua"
fi

if [[ -e "${KOREADER}/frontend/apps/reader/modules/readerrolling.lua" ]]; then
  cp -a "${KOREADER}/frontend/apps/reader/modules/readerrolling.lua" "${BACKUP}/.adds/koreader/frontend/apps/reader/modules/readerrolling.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/elements/reader_menu_order.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/elements/reader_menu_order.lua" "${BACKUP}/.adds/koreader/frontend/ui/elements/reader_menu_order.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/elements/filemanager_menu_order.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/elements/filemanager_menu_order.lua" "${BACKUP}/.adds/koreader/frontend/ui/elements/filemanager_menu_order.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/elements/mass_storage.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/elements/mass_storage.lua" "${BACKUP}/.adds/koreader/frontend/ui/elements/mass_storage.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/widget/filechooser.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/widget/filechooser.lua" "${BACKUP}/.adds/koreader/frontend/ui/widget/filechooser.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/widget/eventlistener.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/widget/eventlistener.lua" "${BACKUP}/.adds/koreader/frontend/ui/widget/eventlistener.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/widget/container/inputcontainer.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/widget/container/inputcontainer.lua" "${BACKUP}/.adds/koreader/frontend/ui/widget/container/inputcontainer.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/widget/container/widgetcontainer.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/widget/container/widgetcontainer.lua" "${BACKUP}/.adds/koreader/frontend/ui/widget/container/widgetcontainer.lua"
fi

if [[ -e "${KOREADER}/ffi/mupdf.lua" ]]; then
  cp -a "${KOREADER}/ffi/mupdf.lua" "${BACKUP}/.adds/koreader/ffi/mupdf.lua"
fi

if [[ -e "${KOREADER}/ffi/xxhash.lua" ]]; then
  cp -a "${KOREADER}/ffi/xxhash.lua" "${BACKUP}/.adds/koreader/ffi/xxhash.lua"
fi

if [[ -e "${KOREADER}/ffi/xxhash_h.lua" ]]; then
  cp -a "${KOREADER}/ffi/xxhash_h.lua" "${BACKUP}/.adds/koreader/ffi/xxhash_h.lua"
fi

if [[ -e "${KOREADER}/frontend/cache.lua" ]]; then
  cp -a "${KOREADER}/frontend/cache.lua" "${BACKUP}/.adds/koreader/frontend/cache.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/uimanager.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/uimanager.lua" "${BACKUP}/.adds/koreader/frontend/ui/uimanager.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/menusorter.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/menusorter.lua" "${BACKUP}/.adds/koreader/frontend/ui/menusorter.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/network/manager.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/network/manager.lua" "${BACKUP}/.adds/koreader/frontend/ui/network/manager.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/network/wpa_supplicant.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/network/wpa_supplicant.lua" "${BACKUP}/.adds/koreader/frontend/ui/network/wpa_supplicant.lua"
fi

if [[ -e "${KOREADER}/frontend/ui/widget/networksetting.lua" ]]; then
  cp -a "${KOREADER}/frontend/ui/widget/networksetting.lua" "${BACKUP}/.adds/koreader/frontend/ui/widget/networksetting.lua"
fi

if [[ -e "${KOREADER}/frontend/document/credocument.lua" ]]; then
  cp -a "${KOREADER}/frontend/document/credocument.lua" "${BACKUP}/.adds/koreader/frontend/document/credocument.lua"
fi

if [[ -e "${KOREADER}/frontend/document/doccache.lua" ]]; then
  cp -a "${KOREADER}/frontend/document/doccache.lua" "${BACKUP}/.adds/koreader/frontend/document/doccache.lua"
fi

if [[ -e "${KOREADER}/libs/libblitbuffer.so" ]]; then
  cp -a "${KOREADER}/libs/libblitbuffer.so" "${BACKUP}/.adds/koreader/libs/libblitbuffer.so"
fi

if [[ -e "${KOREADER}/libs/libkoreader-input.so" ]]; then
  cp -a "${KOREADER}/libs/libkoreader-input.so" "${BACKUP}/.adds/koreader/libs/libkoreader-input.so"
fi

if [[ -e "${KOREADER}/libs/libwrap-mupdf.so" ]]; then
  cp -a "${KOREADER}/libs/libwrap-mupdf.so" "${BACKUP}/.adds/koreader/libs/libwrap-mupdf.so"
fi

if [[ -e "${KOREADER}/libs/libxxhash.so.0" ]]; then
  cp -a "${KOREADER}/libs/libxxhash.so.0" "${BACKUP}/.adds/koreader/libs/libxxhash.so.0"
fi

if [[ -e "${KOREADER}/libs/libkoreader-xtext.so" ]]; then
  cp -a "${KOREADER}/libs/libkoreader-xtext.so" "${BACKUP}/.adds/koreader/libs/libkoreader-xtext.so"
fi

if [[ -e "${KOREADER}/libs/libkoreader-cre.so" ]]; then
  cp -a "${KOREADER}/libs/libkoreader-cre.so" "${BACKUP}/.adds/koreader/libs/libkoreader-cre.so"
fi

if [[ -e "${KOREADER}/libs/libttsreader-player.so" ]]; then
  cp -a "${KOREADER}/libs/libttsreader-player.so" "${BACKUP}/.adds/koreader/libs/libttsreader-player.so"
fi

if [[ -e "${KOREADER}/bin/ttsreader-play" ]]; then
  cp -a "${KOREADER}/bin/ttsreader-play" "${BACKUP}/.adds/koreader/bin/ttsreader-play"
fi

if [[ -e "${KOREADER}/bin/kobo-usb-dhcpd" ]]; then
  cp -a "${KOREADER}/bin/kobo-usb-dhcpd" "${BACKUP}/.adds/koreader/bin/kobo-usb-dhcpd"
fi

if [[ -d "${KOREADER}/plugins/libra2perf.koplugin" ]]; then
  cp -a "${KOREADER}/plugins/libra2perf.koplugin" "${BACKUP}/.adds/koreader/plugins/"
fi

if [[ -d "${KOREADER}/plugins/SSH.koplugin" ]]; then
  cp -a "${KOREADER}/plugins/SSH.koplugin" "${BACKUP}/.adds/koreader/plugins/"
fi

if [[ -d "${KOREADER}/plugins/ttsreader.koplugin" ]]; then
  cp -a "${KOREADER}/plugins/ttsreader.koplugin" "${BACKUP}/.adds/koreader/plugins/"
fi

mkdir -p "${KOREADER}/frontend/document"
mkdir -p "${KOREADER}/frontend"
mkdir -p "${KOREADER}/frontend/apps/filemanager"
mkdir -p "${KOREADER}/frontend/apps/reader/modules"
mkdir -p "${KOREADER}/frontend/device"
mkdir -p "${KOREADER}/frontend/device/kobo"
mkdir -p "${KOREADER}/frontend/ui/elements"
mkdir -p "${KOREADER}/frontend/ui/network"
mkdir -p "${KOREADER}/frontend/ui/widget"
mkdir -p "${KOREADER}/frontend/ui/widget/container"
mkdir -p "${KOREADER}/ffi"
mkdir -p "${KOREADER}/bin"
mkdir -p "${KOREADER}/libs"
mkdir -p "${KOREADER}/plugins"
mkdir -p "${KOREADER}/plugins/SSH.koplugin"
mkdir -p "${MOUNT}/Books"
cp -a "${STAGE}/defaults.lua" "${KOREADER}/defaults.lua.tmp-${STAMP}"
mv -f "${KOREADER}/defaults.lua.tmp-${STAMP}" "${KOREADER}/defaults.lua"
cp -a "${STAGE}/ffi/blitbuffer.lua" "${KOREADER}/ffi/blitbuffer.lua.tmp-${STAMP}"
mv -f "${KOREADER}/ffi/blitbuffer.lua.tmp-${STAMP}" "${KOREADER}/ffi/blitbuffer.lua"
cp -a "${STAGE}/ffi/mupdf.lua" "${KOREADER}/ffi/mupdf.lua.tmp-${STAMP}"
mv -f "${KOREADER}/ffi/mupdf.lua.tmp-${STAMP}" "${KOREADER}/ffi/mupdf.lua"
cp -a "${STAGE}/ffi/xxhash.lua" "${KOREADER}/ffi/xxhash.lua.tmp-${STAMP}"
mv -f "${KOREADER}/ffi/xxhash.lua.tmp-${STAMP}" "${KOREADER}/ffi/xxhash.lua"
cp -a "${STAGE}/ffi/xxhash_h.lua" "${KOREADER}/ffi/xxhash_h.lua.tmp-${STAMP}"
mv -f "${KOREADER}/ffi/xxhash_h.lua.tmp-${STAMP}" "${KOREADER}/ffi/xxhash_h.lua"
cp -a "${STAGE}/frontend/cache.lua" "${KOREADER}/frontend/cache.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/cache.lua.tmp-${STAMP}" "${KOREADER}/frontend/cache.lua"
cp -a "${STAGE}/frontend/document/koptinterface.lua" "${KOREADER}/frontend/document/koptinterface.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/document/koptinterface.lua.tmp-${STAMP}" "${KOREADER}/frontend/document/koptinterface.lua"
cp -a "${STAGE}/frontend/document/credocument.lua" "${KOREADER}/frontend/document/credocument.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/document/credocument.lua.tmp-${STAMP}" "${KOREADER}/frontend/document/credocument.lua"
cp -a "${STAGE}/frontend/document/doccache.lua" "${KOREADER}/frontend/document/doccache.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/document/doccache.lua.tmp-${STAMP}" "${KOREADER}/frontend/document/doccache.lua"
cp -a "${STAGE}/frontend/document/document.lua" "${KOREADER}/frontend/document/document.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/document/document.lua.tmp-${STAMP}" "${KOREADER}/frontend/document/document.lua"
cp -a "${STAGE}/frontend/document/documentregistry.lua" "${KOREADER}/frontend/document/documentregistry.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/document/documentregistry.lua.tmp-${STAMP}" "${KOREADER}/frontend/document/documentregistry.lua"
cp -a "${STAGE}/frontend/pluginloader.lua" "${KOREADER}/frontend/pluginloader.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/pluginloader.lua.tmp-${STAMP}" "${KOREADER}/frontend/pluginloader.lua"
cp -a "${STAGE}/frontend/dispatcher.lua" "${KOREADER}/frontend/dispatcher.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/dispatcher.lua.tmp-${STAMP}" "${KOREADER}/frontend/dispatcher.lua"
cp -a "${STAGE}/frontend/device/input.lua" "${KOREADER}/frontend/device/input.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/device/input.lua.tmp-${STAMP}" "${KOREADER}/frontend/device/input.lua"
cp -a "${STAGE}/frontend/device/gesturedetector.lua" "${KOREADER}/frontend/device/gesturedetector.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/device/gesturedetector.lua.tmp-${STAMP}" "${KOREADER}/frontend/device/gesturedetector.lua"
cp -a "${STAGE}/frontend/device/kobo/device.lua" "${KOREADER}/frontend/device/kobo/device.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/device/kobo/device.lua.tmp-${STAMP}" "${KOREADER}/frontend/device/kobo/device.lua"
cp -a "${STAGE}/frontend/apps/filemanager/filemanager.lua" "${KOREADER}/frontend/apps/filemanager/filemanager.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/filemanager/filemanager.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/filemanager/filemanager.lua"
cp -a "${STAGE}/frontend/apps/filemanager/filemanagerbookinfo.lua" "${KOREADER}/frontend/apps/filemanager/filemanagerbookinfo.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/filemanager/filemanagerbookinfo.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/filemanager/filemanagerbookinfo.lua"
cp -a "${STAGE}/frontend/apps/filemanager/filemanagercollection.lua" "${KOREADER}/frontend/apps/filemanager/filemanagercollection.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/filemanager/filemanagercollection.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/filemanager/filemanagercollection.lua"
cp -a "${STAGE}/frontend/apps/filemanager/filemanagerfilesearcher.lua" "${KOREADER}/frontend/apps/filemanager/filemanagerfilesearcher.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/filemanager/filemanagerfilesearcher.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/filemanager/filemanagerfilesearcher.lua"
cp -a "${STAGE}/frontend/apps/filemanager/filemanagerhistory.lua" "${KOREADER}/frontend/apps/filemanager/filemanagerhistory.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/filemanager/filemanagerhistory.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/filemanager/filemanagerhistory.lua"
cp -a "${STAGE}/frontend/apps/filemanager/filemanagermenu.lua" "${KOREADER}/frontend/apps/filemanager/filemanagermenu.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/filemanager/filemanagermenu.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/filemanager/filemanagermenu.lua"
cp -a "${STAGE}/frontend/apps/filemanager/filemanagershortcuts.lua" "${KOREADER}/frontend/apps/filemanager/filemanagershortcuts.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/filemanager/filemanagershortcuts.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/filemanager/filemanagershortcuts.lua"
cp -a "${STAGE}/frontend/apps/filemanager/filemanagerutil.lua" "${KOREADER}/frontend/apps/filemanager/filemanagerutil.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/filemanager/filemanagerutil.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/filemanager/filemanagerutil.lua"
cp -a "${STAGE}/frontend/apps/reader/readerui.lua" "${KOREADER}/frontend/apps/reader/readerui.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/reader/readerui.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/reader/readerui.lua"
cp -a "${STAGE}/frontend/apps/reader/modules/readerfooter.lua" "${KOREADER}/frontend/apps/reader/modules/readerfooter.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/reader/modules/readerfooter.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/reader/modules/readerfooter.lua"
cp -a "${STAGE}/frontend/apps/reader/modules/readerhighlight.lua" "${KOREADER}/frontend/apps/reader/modules/readerhighlight.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/reader/modules/readerhighlight.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/reader/modules/readerhighlight.lua"
cp -a "${STAGE}/frontend/apps/reader/modules/readerkoptlistener.lua" "${KOREADER}/frontend/apps/reader/modules/readerkoptlistener.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/reader/modules/readerkoptlistener.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/reader/modules/readerkoptlistener.lua"
cp -a "${STAGE}/frontend/apps/reader/modules/readermenu.lua" "${KOREADER}/frontend/apps/reader/modules/readermenu.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/reader/modules/readermenu.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/reader/modules/readermenu.lua"
cp -a "${STAGE}/frontend/apps/reader/modules/readerview.lua" "${KOREADER}/frontend/apps/reader/modules/readerview.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/reader/modules/readerview.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/reader/modules/readerview.lua"
cp -a "${STAGE}/frontend/apps/reader/modules/readerzooming.lua" "${KOREADER}/frontend/apps/reader/modules/readerzooming.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/reader/modules/readerzooming.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/reader/modules/readerzooming.lua"
cp -a "${STAGE}/frontend/apps/reader/modules/readerrolling.lua" "${KOREADER}/frontend/apps/reader/modules/readerrolling.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/apps/reader/modules/readerrolling.lua.tmp-${STAMP}" "${KOREADER}/frontend/apps/reader/modules/readerrolling.lua"
cp -a "${STAGE}/frontend/ui/menusorter.lua" "${KOREADER}/frontend/ui/menusorter.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/menusorter.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/menusorter.lua"
cp -a "${STAGE}/frontend/ui/uimanager.lua" "${KOREADER}/frontend/ui/uimanager.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/uimanager.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/uimanager.lua"
cp -a "${STAGE}/frontend/ui/network/manager.lua" "${KOREADER}/frontend/ui/network/manager.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/network/manager.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/network/manager.lua"
cp -a "${STAGE}/frontend/ui/network/wpa_supplicant.lua" "${KOREADER}/frontend/ui/network/wpa_supplicant.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/network/wpa_supplicant.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/network/wpa_supplicant.lua"
cp -a "${STAGE}/frontend/ui/elements/reader_menu_order.lua" "${KOREADER}/frontend/ui/elements/reader_menu_order.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/elements/reader_menu_order.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/elements/reader_menu_order.lua"
cp -a "${STAGE}/frontend/ui/elements/filemanager_menu_order.lua" "${KOREADER}/frontend/ui/elements/filemanager_menu_order.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/elements/filemanager_menu_order.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/elements/filemanager_menu_order.lua"
cp -a "${STAGE}/frontend/ui/elements/mass_storage.lua" "${KOREADER}/frontend/ui/elements/mass_storage.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/elements/mass_storage.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/elements/mass_storage.lua"
cp -a "${STAGE}/frontend/ui/widget/eventlistener.lua" "${KOREADER}/frontend/ui/widget/eventlistener.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/widget/eventlistener.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/widget/eventlistener.lua"
cp -a "${STAGE}/frontend/ui/widget/networksetting.lua" "${KOREADER}/frontend/ui/widget/networksetting.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/widget/networksetting.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/widget/networksetting.lua"
cp -a "${STAGE}/frontend/ui/widget/container/inputcontainer.lua" "${KOREADER}/frontend/ui/widget/container/inputcontainer.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/widget/container/inputcontainer.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/widget/container/inputcontainer.lua"
cp -a "${STAGE}/frontend/ui/widget/container/widgetcontainer.lua" "${KOREADER}/frontend/ui/widget/container/widgetcontainer.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/widget/container/widgetcontainer.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/widget/container/widgetcontainer.lua"
cp -a "${STAGE}/frontend/ui/widget/filechooser.lua" "${KOREADER}/frontend/ui/widget/filechooser.lua.tmp-${STAMP}"
mv -f "${KOREADER}/frontend/ui/widget/filechooser.lua.tmp-${STAMP}" "${KOREADER}/frontend/ui/widget/filechooser.lua"
cp -a "${STAGE}/koreader.sh" "${KOREADER}/koreader.sh.tmp-${STAMP}"
mv -f "${KOREADER}/koreader.sh.tmp-${STAMP}" "${KOREADER}/koreader.sh"
cp -a "${STAGE}/enable-wifi.sh" "${KOREADER}/enable-wifi.sh.tmp-${STAMP}"
mv -f "${KOREADER}/enable-wifi.sh.tmp-${STAMP}" "${KOREADER}/enable-wifi.sh"
cp -a "${STAGE}/disable-wifi.sh" "${KOREADER}/disable-wifi.sh.tmp-${STAMP}"
mv -f "${KOREADER}/disable-wifi.sh.tmp-${STAMP}" "${KOREADER}/disable-wifi.sh"
cp -a "${STAGE}/obtain-ip.sh" "${KOREADER}/obtain-ip.sh.tmp-${STAMP}"
mv -f "${KOREADER}/obtain-ip.sh.tmp-${STAMP}" "${KOREADER}/obtain-ip.sh"
cp -a "${STAGE}/release-ip.sh" "${KOREADER}/release-ip.sh.tmp-${STAMP}"
mv -f "${KOREADER}/release-ip.sh.tmp-${STAMP}" "${KOREADER}/release-ip.sh"
cp -a "${STAGE}/restore-wifi-async.sh" "${KOREADER}/restore-wifi-async.sh.tmp-${STAMP}"
mv -f "${KOREADER}/restore-wifi-async.sh.tmp-${STAMP}" "${KOREADER}/restore-wifi-async.sh"
cp -a "${STAGE}/usb-network-ssh.sh" "${KOREADER}/usb-network-ssh.sh.tmp-${STAMP}"
mv -f "${KOREADER}/usb-network-ssh.sh.tmp-${STAMP}" "${KOREADER}/usb-network-ssh.sh"
cp -a "${STAGE}/libra2-optimize.sh" "${KOREADER}/libra2-optimize.sh.tmp-${STAMP}"
mv -f "${KOREADER}/libra2-optimize.sh.tmp-${STAMP}" "${KOREADER}/libra2-optimize.sh"
cp -a "${STAGE}/libra2-preflight.lua" "${KOREADER}/libra2-preflight.lua.tmp-${STAMP}"
mv -f "${KOREADER}/libra2-preflight.lua.tmp-${STAMP}" "${KOREADER}/libra2-preflight.lua"
chmod 755 "${KOREADER}/koreader.sh" "${KOREADER}/enable-wifi.sh" "${KOREADER}/disable-wifi.sh" "${KOREADER}/obtain-ip.sh" "${KOREADER}/release-ip.sh" "${KOREADER}/restore-wifi-async.sh" "${KOREADER}/usb-network-ssh.sh" "${KOREADER}/libra2-optimize.sh"

if [[ -f "${STAGE}/libs/libblitbuffer.so" ]]; then
  cp -a "${STAGE}/libs/libblitbuffer.so" "${KOREADER}/libs/libblitbuffer.so.tmp-${STAMP}"
  mv -f "${KOREADER}/libs/libblitbuffer.so.tmp-${STAMP}" "${KOREADER}/libs/libblitbuffer.so"
fi

if [[ -f "${STAGE}/libs/libkoreader-input.so" ]]; then
  cp -a "${STAGE}/libs/libkoreader-input.so" "${KOREADER}/libs/libkoreader-input.so.tmp-${STAMP}"
  mv -f "${KOREADER}/libs/libkoreader-input.so.tmp-${STAMP}" "${KOREADER}/libs/libkoreader-input.so"
fi

if [[ -f "${STAGE}/libs/libwrap-mupdf.so" ]]; then
  cp -a "${STAGE}/libs/libwrap-mupdf.so" "${KOREADER}/libs/libwrap-mupdf.so.tmp-${STAMP}"
  mv -f "${KOREADER}/libs/libwrap-mupdf.so.tmp-${STAMP}" "${KOREADER}/libs/libwrap-mupdf.so"
fi

if [[ -f "${STAGE}/libs/libxxhash.so.0" ]]; then
  cp -a "${STAGE}/libs/libxxhash.so.0" "${KOREADER}/libs/libxxhash.so.0.tmp-${STAMP}"
  mv -f "${KOREADER}/libs/libxxhash.so.0.tmp-${STAMP}" "${KOREADER}/libs/libxxhash.so.0"
fi

if [[ -f "${STAGE}/libs/libkoreader-xtext.so" ]]; then
  cp -a "${STAGE}/libs/libkoreader-xtext.so" "${KOREADER}/libs/libkoreader-xtext.so.tmp-${STAMP}"
  mv -f "${KOREADER}/libs/libkoreader-xtext.so.tmp-${STAMP}" "${KOREADER}/libs/libkoreader-xtext.so"
fi

if [[ -f "${STAGE}/libs/libkoreader-cre.so" ]]; then
  cp -a "${STAGE}/libs/libkoreader-cre.so" "${KOREADER}/libs/libkoreader-cre.so.tmp-${STAMP}"
  mv -f "${KOREADER}/libs/libkoreader-cre.so.tmp-${STAMP}" "${KOREADER}/libs/libkoreader-cre.so"
fi

if [[ -f "${STAGE}/libs/libttsreader-player.so" ]]; then
  cp -a "${STAGE}/libs/libttsreader-player.so" "${KOREADER}/libs/libttsreader-player.so.tmp-${STAMP}"
  mv -f "${KOREADER}/libs/libttsreader-player.so.tmp-${STAMP}" "${KOREADER}/libs/libttsreader-player.so"
fi

if [[ -f "${STAGE}/bin/ttsreader-play" ]]; then
  cp -a "${STAGE}/bin/ttsreader-play" "${KOREADER}/bin/ttsreader-play.tmp-${STAMP}"
  mv -f "${KOREADER}/bin/ttsreader-play.tmp-${STAMP}" "${KOREADER}/bin/ttsreader-play"
  chmod 755 "${KOREADER}/bin/ttsreader-play"
fi

if [[ -f "${STAGE}/bin/kobo-usb-dhcpd" ]]; then
  cp -a "${STAGE}/bin/kobo-usb-dhcpd" "${KOREADER}/bin/kobo-usb-dhcpd.tmp-${STAMP}"
  mv -f "${KOREADER}/bin/kobo-usb-dhcpd.tmp-${STAMP}" "${KOREADER}/bin/kobo-usb-dhcpd"
  chmod 755 "${KOREADER}/bin/kobo-usb-dhcpd"
fi

PLUGIN_TARGET="${KOREADER}/plugins/libra2perf.koplugin"
PLUGIN_OLD="${KOREADER}/plugins/libra2perf.koplugin.old-${STAMP}"
if [[ -d "${PLUGIN_TARGET}" ]]; then
  mv "${PLUGIN_TARGET}" "${PLUGIN_OLD}"
fi
if mv "${STAGE}/plugins/libra2perf.koplugin" "${PLUGIN_TARGET}"; then
  rm -rf "${PLUGIN_OLD}"
else
  if [[ -d "${PLUGIN_OLD}" ]]; then
    mv "${PLUGIN_OLD}" "${PLUGIN_TARGET}"
  fi
  exit 1
fi

cp -a "${STAGE}/plugins/SSH.koplugin/_meta.lua" "${KOREADER}/plugins/SSH.koplugin/_meta.lua.tmp-${STAMP}"
mv -f "${KOREADER}/plugins/SSH.koplugin/_meta.lua.tmp-${STAMP}" "${KOREADER}/plugins/SSH.koplugin/_meta.lua"
cp -a "${STAGE}/plugins/SSH.koplugin/main.lua" "${KOREADER}/plugins/SSH.koplugin/main.lua.tmp-${STAMP}"
mv -f "${KOREADER}/plugins/SSH.koplugin/main.lua.tmp-${STAMP}" "${KOREADER}/plugins/SSH.koplugin/main.lua"

PLUGIN_TARGET="${KOREADER}/plugins/ttsreader.koplugin"
PLUGIN_OLD="${KOREADER}/plugins/ttsreader.koplugin.old-${STAMP}"
if [[ -d "${PLUGIN_TARGET}" ]]; then
  mv "${PLUGIN_TARGET}" "${PLUGIN_OLD}"
fi
if mv "${STAGE}/plugins/ttsreader.koplugin" "${PLUGIN_TARGET}"; then
  rm -rf "${PLUGIN_OLD}"
else
  if [[ -d "${PLUGIN_OLD}" ]]; then
    mv "${PLUGIN_OLD}" "${PLUGIN_TARGET}"
  fi
  exit 1
fi

chmod 755 "${KOREADER}/koreader.sh"
chmod 755 "${KOREADER}/libra2-optimize.sh"
sync

echo "Deployed Libra 2 overlay to ${MOUNT}"
echo "Backup: ${BACKUP}"
