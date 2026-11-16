#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_sim.sh — аналіз, елаборація та запуск симуляції UART у GHDL.
# Лабораторна робота №3, Бартошко О.І., КІ-408, варіант 1 (UART / VHDL).
#
# Використання:
#   sim/run_sim.sh            # реальні параметри: 50 МГц, 115200 бод
#   FAST=1 sim/run_sim.sh     # швидкий режим: 50 МГц, 781250 бод (DIVISOR=4)
#   NO_VCD=1 sim/run_sim.sh   # без запису осцилограм (для CI)
#
# Результати: build/sim_log.txt (лог), build/uart.vcd (осцилограми для GTKWave)
# Код виходу != 0, якщо спрацював assert severity failure або немає "TEST PASSED".
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"
cd "$BUILD"

GHDL="${GHDL:-ghdl}"
# macOS: прибирає попередження лінкера про версію SDK (на Linux ігнорується)
if [[ "$(uname)" == "Darwin" ]]; then
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$(sw_vers -productVersion | cut -d. -f1).0}"
fi
GFLAGS=(--std=08 --workdir="$BUILD" -frelaxed)
STOP_TIME="${STOP_TIME:-20ms}"     # аварійна межа часу симуляції

SOURCES=(
  "$ROOT/rtl/baud_gen.vhd"
  "$ROOT/rtl/uart_tx.vhd"
  "$ROOT/rtl/uart_rx.vhd"
  "$ROOT/rtl/uart_top.vhd"
  "$ROOT/tb/tb_uart.vhd"
)

GENERICS=()
if [[ "${FAST:-0}" == "1" ]]; then
  GENERICS+=(-gG_BAUD=781250)
fi

RUN_OPTS=(--stop-time="$STOP_TIME" --ieee-asserts=disable-at-0)
if [[ "${NO_VCD:-0}" != "1" ]]; then
  RUN_OPTS+=(--vcd="$BUILD/uart.vcd")
fi

rm -f "$BUILD"/work-obj08.cf   # чиста бібліотека work

echo "[1/3] Аналіз VHDL-файлів"
"$GHDL" -a "${GFLAGS[@]}" "${SOURCES[@]}"
echo "[2/3] Елаборація tb_uart"
"$GHDL" -e "${GFLAGS[@]}" tb_uart
echo "[3/3] Симуляція ${GENERICS[*]:-(параметри за замовчуванням)}"
set +e
"$GHDL" -r "${GFLAGS[@]}" tb_uart ${GENERICS[@]+"${GENERICS[@]}"} "${RUN_OPTS[@]}" 2>&1 | tee "$BUILD/sim_log.txt"
rc=${PIPESTATUS[0]}
set -e

if [[ $rc -ne 0 ]]; then
  echo "SIMULATION FAILED (код виходу $rc)"
  exit "$rc"
fi
if ! grep -q "TEST PASSED" "$BUILD/sim_log.txt"; then
  echo "SIMULATION FAILED: рядок 'TEST PASSED' не знайдено"
  exit 1
fi
echo "Симуляцію завершено успішно. Лог: build/sim_log.txt"
