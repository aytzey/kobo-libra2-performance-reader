#!/bin/sh

# Kobo Libra 2 only, reversible OS tuning for KOReader sessions.
# The stock launcher already handles Nickel teardown, fbdepth, and a safe
# governor. This hook only tunes VM writeback and onboard storage for document
# open/render bursts, then restores the previous state. Keeping the CPU floor
# raised for the whole reading session costs idle power without improving page
# turns on Libra 2.

set -u

STATE_DIR="${KO_LIBRA2_STATE_DIR:-/tmp/koreader-libra2-optimize}"
SYSFS_ROOT="${KO_LIBRA2_SYSFS_ROOT:-/sys}"
PROCFS_ROOT="${KO_LIBRA2_PROCFS_ROOT:-/proc}"
ONBOARD_ROOT="${KO_LIBRA2_ONBOARD_ROOT:-/mnt/onboard}"
KOBO_VERSION="${KO_LIBRA2_KOBO_VERSION:-${ONBOARD_ROOT}/.kobo/version}"

log() {
    echo "libra2-optimize: $*"
}

is_libra2() {
    [ -r "${KOBO_VERSION}" ] || return 1
    model="$(sed -n '1{s/[[:space:]]*$//;s/^.*\([0-9][0-9][0-9]\)$/\1/p;q;}' "${KOBO_VERSION}" 2>/dev/null)"
    [ "${model}" = "388" ]
}

state_name() {
    echo "$1" | sed 's#[^A-Za-z0-9_.-]#_#g'
}

save_value() {
    path="$1"
    [ -e "${path}" ] || return 1
    key="$(state_name "${path}")"
    [ -r "${STATE_DIR}/${key}" ] && return 0
    cat "${path}" >"${STATE_DIR}/${key}" 2>/dev/null || return 1
}

restore_value() {
    path="$1"
    key="$(state_name "${path}")"
    [ -e "${path}" ] || return 0
    [ -r "${STATE_DIR}/${key}" ] || return 0
    value="$(cat "${STATE_DIR}/${key}" 2>/dev/null)" || return 0
    [ -n "${value}" ] || return 0
    case "${path}" in
        */scheduler)
            active="$(printf '%s\n' "${value}" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')"
            [ -n "${active}" ] && value="${active}"
            ;;
    esac
    echo "${value}" >"${path}" 2>/dev/null || true
}

write_if_available() {
    path="$1"
    value="$2"
    [ -e "${path}" ] || return 1
    echo "${value}" >"${path}" 2>/dev/null || return 1
}

save_scheduler() {
    path="$1"
    [ -e "${path}" ] || return 1
    key="$(state_name "${path}")"
    [ -r "${STATE_DIR}/${key}" ] && return 0
    active="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "${path}" 2>/dev/null || true)"
    [ -n "${active}" ] || active="$(awk '{print $1}' "${path}" 2>/dev/null || true)"
    [ -n "${active}" ] || return 1
    printf '%s\n' "${active}" >"${STATE_DIR}/${key}" 2>/dev/null || return 1
}

# Restore state left by older overlay versions that changed CPU policy.
restore_cpu_mode() {
    for policy in "${SYSFS_ROOT}"/devices/system/cpu/cpufreq/policy* "${SYSFS_ROOT}"/devices/system/cpu/cpu*/cpufreq; do
        [ -d "${policy}" ] || continue
        restore_value "${policy}/scaling_min_freq"
        restore_value "${policy}/scaling_governor"
    done
    for governor in "${SYSFS_ROOT}"/devices/system/cpu/cpufreq/interactive "${SYSFS_ROOT}"/devices/system/cpu/cpu*/cpufreq/interactive; do
        [ -d "${governor}" ] || continue
        restore_value "${governor}/timer_rate"
        restore_value "${governor}/min_sample_time"
        restore_value "${governor}/go_hispeed_load"
        restore_value "${governor}/above_hispeed_delay"
    done
}

set_block_device_tuning() {
    read_ahead="${KO_LIBRA2_READ_AHEAD_KB:-1024}"
    case "${read_ahead}" in
        *[!0-9]*|"") read_ahead="1024" ;;
    esac

    for queue in "${SYSFS_ROOT}"/block/mmcblk*/queue; do
        [ -d "${queue}" ] || continue

        if [ -e "${queue}/read_ahead_kb" ]; then
            save_value "${queue}/read_ahead_kb"
            write_if_available "${queue}/read_ahead_kb" "${read_ahead}" && log "read_ahead ${queue} -> ${read_ahead}"
        fi

        if [ -e "${queue}/add_random" ]; then
            save_value "${queue}/add_random"
            write_if_available "${queue}/add_random" "0" && log "add_random ${queue} -> 0"
        fi

        if [ -e "${queue}/iostats" ]; then
            save_value "${queue}/iostats"
            write_if_available "${queue}/iostats" "0" && log "iostats ${queue} -> 0"
        fi

        if [ -e "${queue}/scheduler" ]; then
            save_scheduler "${queue}/scheduler"
            schedulers="$(cat "${queue}/scheduler" 2>/dev/null || true)"
            case " ${schedulers} " in
                *" mq-deadline "*) write_if_available "${queue}/scheduler" "mq-deadline" && log "scheduler ${queue} -> mq-deadline" ;;
                *" deadline "*) write_if_available "${queue}/scheduler" "deadline" && log "scheduler ${queue} -> deadline" ;;
                *" noop "*) write_if_available "${queue}/scheduler" "noop" && log "scheduler ${queue} -> noop" ;;
            esac
        fi
    done
}

restore_block_device_tuning() {
    for queue in "${SYSFS_ROOT}"/block/mmcblk*/queue; do
        [ -d "${queue}" ] || continue
        restore_value "${queue}/read_ahead_kb"
        restore_value "${queue}/add_random"
        restore_value "${queue}/iostats"
        restore_value "${queue}/scheduler"
    done
}

set_vm_tuning() {
    if [ -e "${PROCFS_ROOT}/sys/vm/swappiness" ]; then
        save_value "${PROCFS_ROOT}/sys/vm/swappiness"
        write_if_available "${PROCFS_ROOT}/sys/vm/swappiness" "5" && log "vm.swappiness -> 5"
    fi

    if [ -e "${PROCFS_ROOT}/sys/vm/dirty_writeback_centisecs" ]; then
        save_value "${PROCFS_ROOT}/sys/vm/dirty_writeback_centisecs"
        write_if_available "${PROCFS_ROOT}/sys/vm/dirty_writeback_centisecs" "1500" && log "vm.dirty_writeback_centisecs -> 1500"
    fi
}

restore_vm_tuning() {
    restore_value "${PROCFS_ROOT}/sys/vm/swappiness"
    restore_value "${PROCFS_ROOT}/sys/vm/dirty_writeback_centisecs"
}

start() {
    if ! is_libra2; then
        log "not Libra 2, skipping"
        return 0
    fi

    # A previous overlay may have left a raised CPU floor in this state dir.
    [ ! -d "${STATE_DIR}" ] || stop
    mkdir -p "${STATE_DIR}"
    log "start"
    set_block_device_tuning
    set_vm_tuning
}

stop() {
    [ -d "${STATE_DIR}" ] || return 0
    log "stop"
    restore_vm_tuning
    restore_block_device_tuning
    restore_cpu_mode
    rm -rf "${STATE_DIR}"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
