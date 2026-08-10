#!/bin/sh

SCRIPT_DIR="$(dirname "$0")"
if [ -n "${SCRIPT_DIR}" ] && [ -d "${SCRIPT_DIR}" ]; then
    cd "${SCRIPT_DIR}" || exit 1
fi

USB_IFACE="${USB_IFACE:-usb0}"
USB_DEVICE_IP="${USB_DEVICE_IP:-192.168.2.2}"
USB_HOST_IP="${USB_HOST_IP:-192.168.2.1}"
USB_NETMASK="${USB_NETMASK:-255.255.255.0}"
SSH_PORT="${KOBO_USB_SSH_PORT:-2222}"
PID_PATH="/tmp/dropbear_koreader.pid"
STATE_PATH="/tmp/kobo-usb-network-ssh.state"
UDHCPD_CONF="/tmp/kobo-usb-network-udhcpd.conf"
UDHCPD_PID="/tmp/kobo-usb-network-udhcpd.pid"
USB_DHCPD_PID="/tmp/kobo-usb-network-dhcpd.pid"
USB_DHCPD_LOG="/tmp/kobo-usb-network-dhcpd.log"

log() {
    echo "[$(date)] usb-network-ssh.sh: $*"
}

have_iface() {
    [ -d "/sys/class/net/${USB_IFACE}" ]
}

pid_alive() {
    pid_file="$1"
    [ -f "${pid_file}" ] || return 1
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    [ -n "${pid}" ] || return 1
    [ -d "/proc/${pid}" ]
}

pid_cmd_has() {
    pid_file="$1"
    pattern="$2"
    [ -f "${pid_file}" ] || return 1
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    [ -n "${pid}" ] || return 1
    [ -d "/proc/${pid}" ] || return 1
    tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null | grep -q "${pattern}"
}

clear_stale_pid() {
    pid_file="$1"
    if [ -f "${pid_file}" ] && ! pid_alive "${pid_file}"; then
        rm -f "${pid_file}"
    fi
}

iface_has_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show dev "${USB_IFACE}" 2>/dev/null | grep -q " ${USB_DEVICE_IP}/"
    else
        ifconfig "${USB_IFACE}" 2>/dev/null | grep -q "${USB_DEVICE_IP}"
    fi
}

tcp_port_listening() {
    port_hex="$(awk -v port="${SSH_PORT}" 'BEGIN { printf "%04X", port }' 2>/dev/null || true)"
    [ -n "${port_hex}" ] || return 1
    for table in /proc/net/tcp /proc/net/tcp6; do
        [ -r "${table}" ] || continue
        if awk -v suffix=":${port_hex}" '
            $2 ~ suffix "$" && $4 == "0A" { found = 1; exit }
            END { exit found ? 0 : 1 }
        ' "${table}" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

usb_dhcpd_alive() {
    pid_cmd_has "${USB_DHCPD_PID}" "kobo-usb-dhcpd"
}

udhcpd_alive() {
    pid_cmd_has "${UDHCPD_PID}" "udhcpd"
}

apply_pending_usb_dhcpd() {
    pending="./bin/kobo-usb-dhcpd.pending"
    target="./bin/kobo-usb-dhcpd"
    [ -f "${pending}" ] || return 0

    if usb_dhcpd_alive || ps | grep "[k]obo-usb-dhcpd" >/dev/null 2>&1; then
        log "native DHCP update is pending until the current DHCP helper stops"
        return 0
    fi

    if mv -f "${pending}" "${target}" 2>/dev/null; then
        chmod 755 "${target}" 2>/dev/null || true
        log "applied pending native DHCP helper"
    else
        log "could not apply pending native DHCP helper; keeping ${pending}"
    fi
}

find_module() {
    module="$1"
    for dir in "/drivers/${PLATFORM:-}" "/lib/modules/$(uname -r)" "/drivers"; do
        [ -n "${dir}" ] || continue
        [ -d "${dir}" ] || continue
        path="$(find "${dir}" -name "${module}.ko" 2>/dev/null | head -n 1)"
        if [ -n "${path}" ]; then
            echo "${path}"
            return 0
        fi
    done
    return 1
}

load_g_ether() {
    if have_iface; then
        return 0
    fi

    # Only one legacy USB gadget can be active at a time.
    rmmod g_file_storage 2>/dev/null || true
    rmmod g_mass_storage 2>/dev/null || true

    if command -v modprobe >/dev/null 2>&1; then
        modprobe g_ether dev_addr=02:00:00:00:02:02 host_addr=02:00:00:00:02:01 2>/dev/null || true
    fi
    if ! have_iface; then
        module_path="$(find_module g_ether || true)"
        if [ -n "${module_path}" ]; then
            insmod "${module_path}" dev_addr=02:00:00:00:02:02 host_addr=02:00:00:00:02:01 2>/dev/null || true
        fi
    fi

    have_iface
}

configure_iface() {
    if command -v ip >/dev/null 2>&1; then
        ip link set "${USB_IFACE}" up 2>/dev/null || true
        ip addr flush dev "${USB_IFACE}" 2>/dev/null || true
        ip addr add "${USB_DEVICE_IP}/24" dev "${USB_IFACE}" 2>/dev/null || true
    else
        ifconfig "${USB_IFACE}" "${USB_DEVICE_IP}" netmask "${USB_NETMASK}" up
    fi
}

start_dhcp() {
    apply_pending_usb_dhcpd
    if [ -x "./bin/kobo-usb-dhcpd" ]; then
        if usb_dhcpd_alive; then
            return 0
        fi
        clear_stale_pid "${USB_DHCPD_PID}"
        ./bin/kobo-usb-dhcpd "${USB_IFACE}" "${USB_DEVICE_IP}" "${USB_HOST_IP}" "${USB_NETMASK}" >"${USB_DHCPD_LOG}" 2>&1 &
        echo "$!" >"${USB_DHCPD_PID}"
        sleep 1
        if usb_dhcpd_alive; then
            log "native DHCP ready for host ${USB_HOST_IP}"
            return 0
        fi
        rm -f "${USB_DHCPD_PID}"
        log "native DHCP exited; falling back to system DHCP helpers"
    fi

    cat >"${UDHCPD_CONF}" <<EOF
start ${USB_HOST_IP}
end ${USB_HOST_IP}
interface ${USB_IFACE}
option subnet ${USB_NETMASK}
option lease 600
pidfile ${UDHCPD_PID}
EOF

    if command -v udhcpd >/dev/null 2>&1; then
        udhcpd -S "${UDHCPD_CONF}" >/tmp/kobo-usb-network-udhcpd.log 2>&1 || true
    elif command -v busybox >/dev/null 2>&1 && busybox udhcpd -h >/dev/null 2>&1; then
        busybox udhcpd -S "${UDHCPD_CONF}" >/tmp/kobo-usb-network-udhcpd.log 2>&1 || true
    else
        log "udhcpd not available; host may need static ${USB_HOST_IP}/24"
    fi
}

dropbear_alive() {
    [ -f "${PID_PATH}" ] || return 1
    pid="$(cat "${PID_PATH}" 2>/dev/null || true)"
    [ -n "${pid}" ] || return 1
    [ -d "/proc/${pid}" ] || return 1
    tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null | grep -q "dropbear"
}

dropbear_ready() {
    if dropbear_alive && tcp_port_listening; then
        return 0
    fi

    # If the pid file is stale but an older Dropbear listener is still alive,
    # accept it instead of starting a competing listener on the same port.
    if tcp_port_listening && ps | grep "[d]ropbear" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

start_dropbear() {
    if dropbear_ready; then
        return 0
    fi
    if dropbear_alive; then
        log "dropbear pid is alive but port ${SSH_PORT} is not listening; starting a fresh listener"
    fi
    rm -f "${PID_PATH}"

    if [ ! -d "/dev/pts" ]; then
        mkdir -p /dev/pts
        mount -t devpts devpts /dev/pts 2>/dev/null || true
    fi
    mkdir -p settings/SSH

    auth_flags=""
    if grep -q '\["SSH_key_only_auth"\] = true' settings.reader.lua 2>/dev/null; then
        auth_flags="-s"
    elif grep -q '\["SSH_allow_no_password"\] = true' settings.reader.lua 2>/dev/null; then
        auth_flags="-n"
    fi

    ./dropbear -E -R -p "${SSH_PORT}" -P "${PID_PATH}" -K 30 -I 0 ${auth_flags} >/tmp/kobo-usb-network-dropbear.log 2>&1 ||
        ./dropbear -E -R -p "${SSH_PORT}" -P "${PID_PATH}" ${auth_flags} >/tmp/kobo-usb-network-dropbear.log 2>&1
}

start_usb_network() {
    if ! load_g_ether; then
        log "g_ether did not create ${USB_IFACE}"
        return 1
    fi

    configure_iface
    start_dhcp
    if ! start_dropbear; then
        log "dropbear did not start on port ${SSH_PORT}"
        return 1
    fi

    {
        echo "iface=${USB_IFACE}"
        echo "device_ip=${USB_DEVICE_IP}"
        echo "host_ip=${USB_HOST_IP}"
        echo "ssh_port=${SSH_PORT}"
    } >"${STATE_PATH}"
    log "ready: ssh root@${USB_DEVICE_IP} -p ${SSH_PORT}"
}

stop_usb_network() {
    if [ -f "${UDHCPD_PID}" ]; then
        kill "$(cat "${UDHCPD_PID}" 2>/dev/null)" 2>/dev/null || true
    fi
    if [ -f "${USB_DHCPD_PID}" ]; then
        kill "$(cat "${USB_DHCPD_PID}" 2>/dev/null)" 2>/dev/null || true
    fi
    killall -q -TERM udhcpd 2>/dev/null || true
    killall -q -TERM kobo-usb-dhcpd 2>/dev/null || true
    sleep 1
    apply_pending_usb_dhcpd
    if have_iface; then
        ifconfig "${USB_IFACE}" 0.0.0.0 down 2>/dev/null || true
    fi
    rmmod g_ether 2>/dev/null || true
    rm -f "${STATE_PATH}" "${UDHCPD_CONF}" "${UDHCPD_PID}" "${USB_DHCPD_PID}"
}

status_usb_network() {
    ok=0
    if have_iface; then
        ifconfig "${USB_IFACE}" 2>/dev/null || true
    else
        echo "iface=${USB_IFACE}"
        echo "iface_ready=0"
        return 1
    fi

    [ -f "${STATE_PATH}" ] && cat "${STATE_PATH}"

    if iface_has_ip; then
        echo "ip_ready=1"
    else
        echo "ip_ready=0"
        ok=1
    fi

    if dropbear_ready; then
        echo "ssh_listening=1"
    else
        echo "ssh_listening=0"
        ok=1
    fi

    if usb_dhcpd_alive; then
        echo "dhcp=native"
        echo "dhcp_pid=$(cat "${USB_DHCPD_PID}" 2>/dev/null)"
    elif udhcpd_alive; then
        echo "dhcp=udhcpd"
        echo "dhcp_pid=$(cat "${UDHCPD_PID}" 2>/dev/null)"
    else
        echo "dhcp=missing"
    fi

    return "${ok}"
}

recover_usb_network() {
    if status_usb_network >/dev/null 2>&1; then
        status_usb_network
        return 0
    fi
    log "recovering USB cable SSH network"
    start_usb_network || return 1
    status_usb_network
}

case "${1:-start}" in
    start)
        start_usb_network
        ;;
    recover)
        recover_usb_network
        ;;
    stop)
        stop_usb_network
        ;;
    status)
        status_usb_network
        ;;
    *)
        echo "usage: $0 {start|recover|stop|status}" >&2
        exit 2
        ;;
esac
