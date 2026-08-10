#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="${ROOT}/dist/koreader-libra2-optimized-overlay.zip"
PACKAGE=1
HOST="${KOBO_USB_HOST:-192.168.2.2}"
PORT="${KOBO_USB_PORT:-2222}"
USER_NAME="${KOBO_USB_USER:-root}"
KNOWN_HOSTS="${KOBO_USB_KNOWN_HOSTS:-/tmp/kobo_usb_known_hosts}"
SSH_BIN="${KOBO_SSH_BIN:-ssh}"
SCP_BIN="${KOBO_SCP_BIN:-scp}"
REMOTE_TMP="${KOBO_REMOTE_TMP:-/tmp}"
REMOTE_ONBOARD="${KOBO_REMOTE_ONBOARD:-/mnt/onboard}"
BACKUP_KEEP="${KOBO_USB_BACKUP_KEEP:-8}"

usage() {
  cat >&2 <<EOF
usage: $0 [--zip PATH] [--no-package]

Deploy the Libra 2 optimized overlay over USB SSH without switching to
mass-storage mode. The live USB DHCP helper is staged as
bin/kobo-usb-dhcpd.pending instead of being overwritten while it serves this
SSH connection.
EOF
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip)
      ZIP="$2"
      PACKAGE=0
      shift 2
      ;;
    --no-package)
      PACKAGE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "${PACKAGE}" -eq 1 ]]; then
  "${ROOT}/scripts/package-libra2-overlay.sh" >/dev/null
fi

if [[ ! -f "${ZIP}" ]]; then
  echo "Overlay zip not found: ${ZIP}" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
REMOTE_ZIP="${REMOTE_TMP%/}/koreader-libra2-overlay-${STAMP}.zip"
REMOTE_LOG="${REMOTE_TMP%/}/koreader-libra2-overlay-${STAMP}.log"

ssh_base=(
  "${SSH_BIN}"
  -p "${PORT}"
  -o "ConnectTimeout=8"
  -o "StrictHostKeyChecking=no"
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
)
scp_base=(
  "${SCP_BIN}"
  -P "${PORT}"
  -o "ConnectTimeout=8"
  -o "StrictHostKeyChecking=no"
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
)

"${scp_base[@]}" "${ZIP}" "${USER_NAME}@${HOST}:${REMOTE_ZIP}"

remote_env="KOBO_REMOTE_ZIP=$(shell_quote "${REMOTE_ZIP}") KOBO_REMOTE_ONBOARD=$(shell_quote "${REMOTE_ONBOARD}") KOBO_REMOTE_LOG=$(shell_quote "${REMOTE_LOG}") KOBO_USB_BACKUP_KEEP=$(shell_quote "${BACKUP_KEEP}")"

"${ssh_base[@]}" "${USER_NAME}@${HOST}" "${remote_env} sh -s" <<'REMOTE'
set -eu

ZIP="${KOBO_REMOTE_ZIP:?missing zip}"
ONBOARD="${KOBO_REMOTE_ONBOARD:-/mnt/onboard}"
LOG="${KOBO_REMOTE_LOG:-/tmp/koreader-libra2-overlay-usb-ssh.log}"
KOREADER="${ONBOARD}/.adds/koreader"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${KOREADER}/.usb-ssh-deploy-backup-${STAMP}"
BACKUP_KEEP="${KOBO_USB_BACKUP_KEEP:-8}"
PENDING_DHCPD="${KOREADER}/bin/kobo-usb-dhcpd.pending"
PENDING_DHCPD_TMP="${PENDING_DHCPD}.tmp"
REMOTE_TMP_DIR="${ZIP%/*}"
if [ "${REMOTE_TMP_DIR}" = "${ZIP}" ] || [ -z "${REMOTE_TMP_DIR}" ]; then
    REMOTE_TMP_DIR="/tmp"
fi

cleanup_remote_tmp() {
    rm -f "${ZIP}" "${PENDING_DHCPD_TMP}" 2>/dev/null || true
    find "${REMOTE_TMP_DIR}" -maxdepth 1 -type f -name 'koreader-libra2-overlay-*.zip' -exec rm -f {} \; 2>/dev/null || true
    for old_log in "${REMOTE_TMP_DIR}"/koreader-libra2-overlay-*.log; do
        [ -e "${old_log}" ] || continue
        [ "${old_log}" = "${LOG}" ] && continue
        rm -f "${old_log}" 2>/dev/null || true
    done
}
trap cleanup_remote_tmp EXIT

cleanup_old_backups() {
    keep="$(printf '%s' "${BACKUP_KEEP}" | sed 's/[^0-9]//g')"
    [ -n "${keep}" ] || keep=8
    [ "${keep}" -gt 0 ] 2>/dev/null || keep=8

    total=0
    for backup_dir in "${KOREADER}"/.usb-ssh-deploy-backup-*; do
        [ -d "${backup_dir}" ] || continue
        total=$((total + 1))
    done
    remove_count=$((total - keep))
    [ "${remove_count}" -gt 0 ] || return 0

    removed=0
    find "${KOREADER}" -maxdepth 1 -type d -name '.usb-ssh-deploy-backup-*' 2>/dev/null | sort | while IFS= read -r backup_dir; do
        [ "${removed}" -lt "${remove_count}" ] || break
        rm -rf "${backup_dir}"
        removed=$((removed + 1))
    done
}

if [ ! -d "${KOREADER}" ]; then
    echo "KOReader not found at ${KOREADER}" >&2
    exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
    echo "unzip not found on Kobo" >&2
    exit 1
fi

mkdir -p "${BACKUP}/plugins" "${BACKUP}/bin" "${BACKUP}/libs"
for path in \
    plugins/ttsreader.koplugin \
    plugins/SSH.koplugin \
    bin/ttsreader-play \
    bin/kobo-usb-dhcpd \
    libs/libttsreader-player.so \
    usb-network-ssh.sh \
    koreader.sh
do
    if [ -e "${KOREADER}/${path}" ]; then
        parent="$(dirname "${path}")"
        mkdir -p "${BACKUP}/${parent}"
        cp -a "${KOREADER}/${path}" "${BACKUP}/${path}" 2>/dev/null || true
    fi
done

for pid in $(ps -o pid,args | awk '/[{]reader[.]lua[}]|[{]koreader[.]sh[}]/ {print $1}'); do
    kill -TERM "$pid" 2>/dev/null || true
done
killall -q -TERM ttsreader-play 2>/dev/null || true
sleep 2
for pid in $(ps -o pid,args | awk '/[{]reader[.]lua[}]|[{]koreader[.]sh[}]/ {print $1}'); do
    kill -KILL "$pid" 2>/dev/null || true
done
killall -q -KILL ttsreader-play 2>/dev/null || true

cd "${ONBOARD}"
rm -f "${PENDING_DHCPD}"
rm -f "${PENDING_DHCPD_TMP}"
unzip -o "${ZIP}" -x ".adds/koreader/bin/kobo-usb-dhcpd" >"${LOG}"
if unzip -p "${ZIP}" ".adds/koreader/bin/kobo-usb-dhcpd" >"${PENDING_DHCPD_TMP}" 2>/dev/null; then
    if [ -f "${KOREADER}/bin/kobo-usb-dhcpd" ] && cmp -s "${PENDING_DHCPD_TMP}" "${KOREADER}/bin/kobo-usb-dhcpd" 2>/dev/null; then
        rm -f "${PENDING_DHCPD_TMP}"
    else
        mv -f "${PENDING_DHCPD_TMP}" "${PENDING_DHCPD}"
        chmod 755 "${PENDING_DHCPD}" 2>/dev/null || true
    fi
else
    rm -f "${PENDING_DHCPD_TMP}"
    rm -f "${PENDING_DHCPD}"
fi

sync
cleanup_old_backups

cd "${KOREADER}"
nohup ./koreader.sh >/tmp/koreader-restart.log 2>&1 &
sleep 4

echo "Deployed overlay over USB SSH"
echo "Backup: ${BACKUP}"
if [ -f "${PENDING_DHCPD}" ]; then
    echo "Pending USB DHCP helper: ${PENDING_DHCPD}"
fi
sha256sum \
    plugins/ttsreader.koplugin/main.lua \
    plugins/ttsreader.koplugin/ttsengine.lua \
    bin/ttsreader-play \
    libs/libttsreader-player.so 2>/dev/null || true
ps -o pid,ppid,stat,args | grep -E "(reader[.]lua|koreader[.]sh)" | grep -v grep || true
REMOTE
