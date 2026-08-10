#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP}"
}
trap cleanup EXIT

FAKE_BIN="${TMP}/bin"
REMOTE_TMP="${TMP}/remote-tmp"
ONBOARD="${TMP}/onboard"
KOREADER="${ONBOARD}/.adds/koreader"
ZIP="${TMP}/overlay.zip"
mkdir -p "${FAKE_BIN}" "${REMOTE_TMP}" "${KOREADER}/bin" "${KOREADER}/plugins/ttsreader.koplugin" "${KOREADER}/libs"
printf 'stale-zip\n' >"${REMOTE_TMP}/koreader-libra2-overlay-stale.zip"
printf 'stale-log\n' >"${REMOTE_TMP}/koreader-libra2-overlay-stale.log"

cat >"${FAKE_BIN}/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
src=""
dst=""
for arg in "$@"; do
  case "${arg}" in
    -P|-o)
      skip_next=1
      ;;
    -*)
      ;;
    *)
      if [[ "${skip_next:-0}" == "1" ]]; then
        skip_next=0
      elif [[ -z "${src}" ]]; then
        src="${arg}"
      else
        dst="${arg}"
      fi
      ;;
  esac
done
dst_path="${dst#*:}"
mkdir -p "$(dirname "${dst_path}")"
cp "${src}" "${dst_path}"
EOF

cat >"${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd=""
for arg in "$@"; do
  case "${arg}" in
    -p|-o)
      skip_next=1
      ;;
    -*)
      ;;
    *@*)
      ;;
    *)
      if [[ "${skip_next:-0}" == "1" ]]; then
        skip_next=0
      else
        cmd="${arg}"
      fi
      ;;
  esac
done
sh -c "${cmd}"
EOF
chmod 755 "${FAKE_BIN}/scp" "${FAKE_BIN}/ssh"

printf 'old-main\n' >"${KOREADER}/plugins/ttsreader.koplugin/main.lua"
printf 'old-engine\n' >"${KOREADER}/plugins/ttsreader.koplugin/ttsengine.lua"
printf 'old-player\n' >"${KOREADER}/bin/ttsreader-play"
printf 'old-dhcpd\n' >"${KOREADER}/bin/kobo-usb-dhcpd"
printf 'old-lib\n' >"${KOREADER}/libs/libttsreader-player.so"
for idx in $(seq -w 1 10); do
  mkdir -p "${KOREADER}/.usb-ssh-deploy-backup-20200101-0000${idx}"
  printf 'old backup %s\n' "${idx}" >"${KOREADER}/.usb-ssh-deploy-backup-20200101-0000${idx}/marker"
done
cat >"${KOREADER}/koreader.sh" <<'EOF'
#!/bin/sh
sleep 1
EOF
chmod 755 "${KOREADER}/koreader.sh" "${KOREADER}/bin/ttsreader-play" "${KOREADER}/bin/kobo-usb-dhcpd"

STAGE="${TMP}/stage/.adds/koreader"
mkdir -p "${STAGE}/bin" "${STAGE}/plugins/ttsreader.koplugin" "${STAGE}/libs"
printf 'new-main\n' >"${STAGE}/plugins/ttsreader.koplugin/main.lua"
printf 'new-engine\n' >"${STAGE}/plugins/ttsreader.koplugin/ttsengine.lua"
printf 'new-player\n' >"${STAGE}/bin/ttsreader-play"
printf 'new-dhcpd\n' >"${STAGE}/bin/kobo-usb-dhcpd"
printf 'new-lib\n' >"${STAGE}/libs/libttsreader-player.so"
(cd "${TMP}/stage" && zip -qr "${ZIP}" .adds)

KOBO_SSH_BIN="${FAKE_BIN}/ssh" \
KOBO_SCP_BIN="${FAKE_BIN}/scp" \
KOBO_REMOTE_TMP="${REMOTE_TMP}" \
KOBO_REMOTE_ONBOARD="${ONBOARD}" \
"${ROOT}/scripts/deploy-libra2-overlay-usb-ssh.sh" --zip "${ZIP}" >/tmp/test-usb-ssh-deploy.out

rg -q 'new-main' "${KOREADER}/plugins/ttsreader.koplugin/main.lua"
rg -q 'new-engine' "${KOREADER}/plugins/ttsreader.koplugin/ttsengine.lua"
rg -q 'new-player' "${KOREADER}/bin/ttsreader-play"
rg -q 'new-lib' "${KOREADER}/libs/libttsreader-player.so"
rg -q 'old-dhcpd' "${KOREADER}/bin/kobo-usb-dhcpd"
rg -q 'new-dhcpd' "${KOREADER}/bin/kobo-usb-dhcpd.pending"
rg -q 'Pending USB DHCP helper' /tmp/test-usb-ssh-deploy.out
if find "${REMOTE_TMP}" -maxdepth 1 -type f -name 'koreader-libra2-overlay-*.zip' | rg -q .; then
  echo "USB SSH deploy should remove remote overlay zip artifacts" >&2
  exit 1
fi
if [[ "$(find "${REMOTE_TMP}" -maxdepth 1 -type f -name 'koreader-libra2-overlay-*.log' | wc -l)" -ne 1 ]]; then
  echo "USB SSH deploy should keep only the latest remote overlay log" >&2
  exit 1
fi
if [[ "$(find "${KOREADER}" -maxdepth 1 -type d -name '.usb-ssh-deploy-backup-*' | wc -l)" -gt 8 ]]; then
  echo "USB SSH deploy should prune old backup directories" >&2
  exit 1
fi
if [[ -d "${KOREADER}/.usb-ssh-deploy-backup-20200101-000001" ]]; then
  echo "USB SSH deploy should remove the oldest backup directories first" >&2
  exit 1
fi

cp "${KOREADER}/bin/kobo-usb-dhcpd.pending" "${KOREADER}/bin/kobo-usb-dhcpd"
rm -f "${KOREADER}/bin/kobo-usb-dhcpd.pending"

KOBO_SSH_BIN="${FAKE_BIN}/ssh" \
KOBO_SCP_BIN="${FAKE_BIN}/scp" \
KOBO_REMOTE_TMP="${REMOTE_TMP}" \
KOBO_REMOTE_ONBOARD="${ONBOARD}" \
"${ROOT}/scripts/deploy-libra2-overlay-usb-ssh.sh" --zip "${ZIP}" >/tmp/test-usb-ssh-deploy-same.out

if [[ -e "${KOREADER}/bin/kobo-usb-dhcpd.pending" ]]; then
  echo "identical USB DHCP helper should not leave a pending copy" >&2
  exit 1
fi
if rg -q 'Pending USB DHCP helper' /tmp/test-usb-ssh-deploy-same.out; then
  echo "identical USB DHCP helper should not report a pending copy" >&2
  exit 1
fi
if find "${REMOTE_TMP}" -maxdepth 1 -type f -name 'koreader-libra2-overlay-*.zip' | rg -q .; then
  echo "USB SSH deploy should not leave remote overlay zip artifacts after repeat deploys" >&2
  exit 1
fi
if [[ "$(find "${REMOTE_TMP}" -maxdepth 1 -type f -name 'koreader-libra2-overlay-*.log' | wc -l)" -ne 1 ]]; then
  echo "USB SSH deploy should keep only one remote overlay log after repeat deploys" >&2
  exit 1
fi
if [[ "$(find "${KOREADER}" -maxdepth 1 -type d -name '.usb-ssh-deploy-backup-*' | wc -l)" -gt 8 ]]; then
  echo "USB SSH deploy should keep backup retention after repeat deploys" >&2
  exit 1
fi

echo "usb ssh deploy fixture passed"
