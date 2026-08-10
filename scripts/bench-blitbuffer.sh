#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/koreader-src"
RUNS="${1:-3}"
OUT_DIR="${ROOT}/dist/benchmarks"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT_DIR}/blitbuffer-hotpaths-${STAMP}.tsv"
TESTLOG="${SRC}/base/build/x86_64-linux-gnu-debug/spec/run/meson-logs/testlog.txt"

if ! [[ "${RUNS}" =~ ^[0-9]+$ ]] || [[ "${RUNS}" -lt 1 ]]; then
  echo "usage: $0 [positive-run-count]" >&2
  exit 2
fi

mkdir -p "${OUT_DIR}"
CASES=(
  bb8_to_bb8
  rgb32_to_bb8
  bb8a_to_bb8
  bb8_to_rgb32
  bb8a_to_rgb32
  bb8a_alpha_to_bb8
  rgb32_alpha_to_bb8
  rgb32_to_bb8_dither
  bb8_to_bb8_dither
)

{
  printf 'run'
  for case_name in "${CASES[@]}"; do
    printf '\t%s_ms' "${case_name}"
  done
  printf '\twall_ms\n'
} | tee "${OUT}"

for run in $(seq 1 "${RUNS}"); do
  start_ns="$(date +%s%N)"
  run_log="$(mktemp)"
  if ! (cd "${SRC}" && ./kodev test --no-build bench koreader-testrunner:blitbuffer >"${run_log}" 2>&1); then
    cat "${run_log}" >&2
    rm -f "${run_log}"
    exit 1
  fi
  rm -f "${run_log}"
  end_ns="$(date +%s%N)"
  wall_ms="$(( (end_ns - start_ns) / 1000000 ))"

  clean_log="$(mktemp)"
  sed -r 's/\x1B\[[0-9;]*[mK]//g' "${TESTLOG}" >"${clean_log}"
  values=()
  for case_name in "${CASES[@]}"; do
    case_ms="$(rg -o "Blitbuffer benchmark: ${case_name} \\(([0-9.]+) ms\\)" -r '$1' "${clean_log}" | tail -1 || true)"
    if [[ -z "${case_ms}" ]]; then
      cat "${clean_log}" >&2
      rm -f "${clean_log}"
      exit 1
    fi
    values+=("${case_ms}")
  done
  rm -f "${clean_log}"

  {
    printf '%s' "${run}"
    for value in "${values[@]}"; do
      printf '\t%s' "${value}"
    done
    printf '\t%s\n' "${wall_ms}"
  } | tee -a "${OUT}"
done

echo "${OUT}"
