#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/koreader-src"
RUNS="${1:-3}"
OUT_DIR="${ROOT}/dist/benchmarks"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT_DIR}/pdf-hotpaths-${STAMP}.tsv"
TESTLOG="${SRC}/base/build/x86_64-linux-gnu-debug/spec/run/meson-logs/testlog.txt"

if ! [[ "${RUNS}" =~ ^[0-9]+$ ]] || [[ "${RUNS}" -lt 1 ]]; then
  echo "usage: $0 [positive-run-count]" >&2
  exit 2
fi

mkdir -p "${OUT_DIR}"
printf 'run\trender_ms\treflow_ms\twall_ms\n' | tee "${OUT}"

for run in $(seq 1 "${RUNS}"); do
  start_ns="$(date +%s%N)"
  run_log="$(mktemp)"
  if ! (cd "${SRC}" && ./kodev test --no-build bench koreader-testrunner:pdf >"${run_log}" 2>&1); then
    cat "${run_log}" >&2
    rm -f "${run_log}"
    exit 1
  fi
  rm -f "${run_log}"
  end_ns="$(date +%s%N)"
  wall_ms="$(( (end_ns - start_ns) / 1000000 ))"

  clean_log="$(mktemp)"
  sed -r 's/\x1B\[[0-9;]*[mK]//g' "${TESTLOG}" >"${clean_log}"
  render_ms="$(rg -o 'PDF benchmark: rendering.*\(([0-9.]+) ms\)' -r '$1' "${clean_log}" | tail -1 || true)"
  reflow_ms="$(rg -o 'PDF benchmark: reflowing.*\(([0-9.]+) ms\)' -r '$1' "${clean_log}" | tail -1 || true)"
  if [[ -z "${render_ms}" || -z "${reflow_ms}" ]]; then
    cat "${clean_log}" >&2
    rm -f "${clean_log}"
    exit 1
  fi
  rm -f "${clean_log}"

  printf '%s\t%s\t%s\t%s\n' "${run}" "${render_ms:-NA}" "${reflow_ms:-NA}" "${wall_ms}" | tee -a "${OUT}"
done

echo "${OUT}"
