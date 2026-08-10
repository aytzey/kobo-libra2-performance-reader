#!/usr/bin/env bash
set -euo pipefail

HOST="${KOBO_USB_HOST:-192.168.2.2}"
PORT="${KOBO_USB_PORT:-2222}"
KNOWN_HOSTS="${KOBO_USB_KNOWN_HOSTS:-/tmp/kobo_usb_known_hosts}"

ssh_cmd=(
  ssh
  -p "${PORT}"
  -o "ConnectTimeout=8"
  -o "StrictHostKeyChecking=no"
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  "root@${HOST}"
)

"${ssh_cmd[@]}" 'cd /mnt/onboard/.adds/koreader
for pid in $(ps -o pid,args | awk '\''/[{]reader[.]lua[}]|[{]koreader[.]sh[}]/ {print $1}'\''); do
    kill -TERM "$pid" 2>/dev/null || true
done
sleep 2
for pid in $(ps -o pid,args | awk '\''/[{]reader[.]lua[}]|[{]koreader[.]sh[}]/ {print $1}'\''); do
    kill -KILL "$pid" 2>/dev/null || true
done
rm -f /tmp/ttsreader-synth*
nohup ./koreader.sh >/tmp/koreader-restart.log 2>&1 &
sleep 3
ps -o pid,ppid,stat,args | grep -E "(reader[.]lua|koreader[.]sh)" | grep -v grep || true'
