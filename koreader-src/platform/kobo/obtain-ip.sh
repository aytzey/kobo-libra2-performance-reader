#!/bin/sh

if [ -z "${INTERFACE:-}" ] || [ "${INTERFACE}" = "eth0" ]; then
    INTERFACE="wlan0"
fi

# NOTE: Close any non-standard fds, so that it doesn't come back to bite us in the ass with USBMS (or sockets) later...
for fd in /proc/"$$"/fd/*; do
    close_me="false"
    fd_id="$(basename "${fd}")"
    fd_path="$(readlink -f "${fd}")"

    if [ -e "${fd}" ] && [ "${fd_id}" -gt 2 ]; then
        if [ -S "${fd}" ]; then
            # Close any and all sockets
            # NOTE: Old busybox builds do something stupid when attempting to canonicalize pipes/sockets...
            #       (i.e., they'll spit out ${fd} as-is, losing any and all mention of a socket/pipe).
            fd_path="$(readlink "${fd}")"
            close_me="true"
        elif [ -p "${fd}" ]; then
            # We *might* be catching temporary pipes created by this very test, se we have to leave pipes alone...
            # Although it would take extremely unlucky timing, as by the time we go through the top-level -e test,
            # said temporary pipe is already gone, and as such we *should* never really enter this branch for temporary pipes ;).
            fd_path="$(readlink "${fd}")"
            close_me="false"
        else
            # NOTE: dash (meaning, in turn, busybox's ash) uses fd 10+ open to /dev/tty or $0 (w/ CLOEXEC)
            # NOTE: The last fd != fd_path check is there to (potentially) whitelist non-regular files we might have failed to handle,
            #       it's designed to match the unhelpful result from old buysbox's readlink -f on non-regular files (c.f., previous notes).
            if [ "${fd_path}" != "/dev/tty" ] && [ "${fd_path}" != "$(readlink -f "${0}")" ] && [ "${fd}" != "${fd_path}" ]; then
                close_me="true"
            else
                close_me="false"
            fi
        fi
    fi

    if [ "${fd_id}" -gt 2 ]; then
        if [ "${close_me}" = "true" ]; then
            eval "exec ${fd_id}>&-"
            [ "${KOBO_FD_DEBUG:-0}" = "1" ] && echo "[obtain-ip.sh] Closed fd ${fd_id} -> ${fd_path}"
        else
            # Try to log something more helpful when old busybox's readlink -f mangled it...
            if [ "${fd}" = "${fd_path}" ]; then
                fd_path="${fd_path} => $(readlink "${fd}")"
                if [ ! -e "${fd}" ]; then
                    # Flag (potentially?) temporary items as such
                    fd_path="${fd_path} (temporary?)"
                fi
            fi
            [ "${KOBO_FD_DEBUG:-0}" = "1" ] && echo "[obtain-ip.sh] Left fd ${fd_id} -> ${fd_path} open"
        fi
    fi
done

has_ipv4() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show dev "${INTERFACE}" 2>/dev/null | grep -q " inet "
    else
        ifconfig "${INTERFACE}" 2>/dev/null | grep -Eq "inet addr:|inet "
    fi
}

if has_ipv4; then
    exit 0
fi

wifi_ready_for_dhcp() {
    # DHCP is pointless until wpa_supplicant has associated with an AP. Avoid
    # blocking the UI for dhcpcd's full carrier timeout while still scanning.
    if command -v wpa_cli >/dev/null 2>&1; then
        status="$(wpa_cli -i "${INTERFACE}" status 2>/dev/null || true)"
        if echo "${status}" | grep -q "^wpa_state=COMPLETED"; then
            return 0
        fi
        if echo "${status}" | grep -q "^wpa_state="; then
            echo "Wi-Fi is not associated yet; skipping DHCP"
            echo "${status}" | grep "^wpa_state=" | head -n 1
            return 1
        fi
    fi
    return 0
}

wifi_ready_for_dhcp || exit 1

wait_for_ipv4() {
    max_wait="${1:-12}"
    waited=0
    while [ "${waited}" -lt "${max_wait}" ]; do
        if has_ipv4; then
            return 0
        fi
        usleep 250000
        waited=$((waited + 1))
    done
    return 1
}

reset_dhcp_clients() {
    killall -q -TERM udhcpc default.script dhcpcd 2>/dev/null || true
    wait_count=0
    while { pkill -0 udhcpc 2>/dev/null || pkill -0 dhcpcd 2>/dev/null; }; do
        if [ "${wait_count}" -ge 20 ]; then
            killall -q -KILL udhcpc default.script dhcpcd 2>/dev/null || true
            break
        fi
        usleep 100000
        wait_count=$((wait_count + 1))
    done
    ifconfig "${INTERFACE}" 0.0.0.0 2>/dev/null || true
}

run_udhcpc() {
    if [ ! -x "/sbin/udhcpc" ]; then
        return 1
    fi
    reset_dhcp_clients
    udhcpc -S -i "${INTERFACE}" -s /etc/udhcpc.d/default.script -t 4 -T 2 -A 1 -n -q
}

DHCP_TIMEOUT="${KOBO_DHCP_TIMEOUT:-8}"

# Prefer dhcpcd because it matches Nickel, but keep it bounded. On some
# Libra 2 boots, a plain renew can linger forever after WPA completes without
# assigning an address; a short udhcpc fallback recovers that state quickly.
if [ -x "/sbin/dhcpcd" ]; then
    reset_dhcp_clients
    dhcpcd -d -t "${DHCP_TIMEOUT}" -w "${INTERFACE}" || true
    wait_for_ipv4 8 && exit 0
fi

run_udhcpc && wait_for_ipv4 8 && exit 0

echo "No IPv4 lease acquired on ${INTERFACE}"
exit 1
