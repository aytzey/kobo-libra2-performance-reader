#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/koreader-src/platform/kobo/libra2-optimize.sh"
TMP="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP}"
}
trap cleanup EXIT

write_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}

assert_file() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(cat "$path")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Expected ${path} to be ${expected}, got ${actual}" >&2
    exit 1
  fi
}

make_fixture() {
  local model="${1:-000388}"
  rm -rf "${TMP}/sys" "${TMP}/proc" "${TMP}/onboard" "${TMP}/state"

  write_file "${TMP}/onboard/.kobo/version" "a,b,c,d,e,00000000-0000-0000-0000-000000000${model}"
  write_file "${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_governor" "powersave"
  write_file "${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors" "powersave ondemand interactive performance"
  write_file "${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq" "396000"
  write_file "${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq" "996000"
  write_file "${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies" "396000 528000 792000 996000"
  write_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/timer_rate" "80000"
  write_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/min_sample_time" "60000"
  write_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/go_hispeed_load" "95"
  write_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/above_hispeed_delay" "80000"
  write_file "${TMP}/sys/block/mmcblk0/queue/read_ahead_kb" "128"
  write_file "${TMP}/sys/block/mmcblk0/queue/add_random" "1"
  write_file "${TMP}/sys/block/mmcblk0/queue/iostats" "1"
  write_file "${TMP}/sys/block/mmcblk0/queue/scheduler" "noop [cfq] deadline"
  write_file "${TMP}/proc/sys/vm/swappiness" "60"
  write_file "${TMP}/proc/sys/vm/dirty_writeback_centisecs" "500"
}

run_hook() {
  KO_LIBRA2_SYSFS_ROOT="${TMP}/sys" \
  KO_LIBRA2_PROCFS_ROOT="${TMP}/proc" \
  KO_LIBRA2_ONBOARD_ROOT="${TMP}/onboard" \
  KO_LIBRA2_STATE_DIR="${TMP}/state" \
    sh "${SCRIPT}" "$1" >/dev/null
}

make_fixture 377
run_hook start
if [[ -d "${TMP}/state" ]]; then
  echo "Non-Libra fixture should not create optimizer state" >&2
  exit 1
fi
assert_file "${TMP}/sys/block/mmcblk0/queue/read_ahead_kb" "128"

make_fixture 388
run_hook start
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_governor" "powersave"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq" "396000"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/timer_rate" "80000"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/min_sample_time" "60000"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/go_hispeed_load" "95"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/above_hispeed_delay" "80000"
assert_file "${TMP}/sys/block/mmcblk0/queue/read_ahead_kb" "1024"
assert_file "${TMP}/sys/block/mmcblk0/queue/add_random" "0"
assert_file "${TMP}/sys/block/mmcblk0/queue/iostats" "0"
assert_file "${TMP}/sys/block/mmcblk0/queue/scheduler" "deadline"
assert_file "${TMP}/proc/sys/vm/swappiness" "5"
assert_file "${TMP}/proc/sys/vm/dirty_writeback_centisecs" "1500"

run_hook start
run_hook stop
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_governor" "powersave"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq" "396000"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/timer_rate" "80000"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/min_sample_time" "60000"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/go_hispeed_load" "95"
assert_file "${TMP}/sys/devices/system/cpu/cpufreq/interactive/above_hispeed_delay" "80000"
assert_file "${TMP}/sys/block/mmcblk0/queue/read_ahead_kb" "128"
assert_file "${TMP}/sys/block/mmcblk0/queue/add_random" "1"
assert_file "${TMP}/sys/block/mmcblk0/queue/iostats" "1"
assert_file "${TMP}/sys/block/mmcblk0/queue/scheduler" "cfq"
assert_file "${TMP}/proc/sys/vm/swappiness" "60"
assert_file "${TMP}/proc/sys/vm/dirty_writeback_centisecs" "500"

# Starting the new hook also clears CPU policy state left by older overlays.
make_fixture 388
legacy_min="${TMP}/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq"
legacy_key="$(printf '%s\n' "${legacy_min}" | sed 's#[^A-Za-z0-9_.-]#_#g')"
write_file "${TMP}/state/${legacy_key}" "396000"
write_file "${legacy_min}" "792000"
run_hook start
assert_file "${legacy_min}" "396000"
run_hook stop

echo "libra2-optimize shell fixture passed"
