#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_synth.sh — синтез і часовий аналіз UART для Lattice iCE40 HX8K (CT256).
# Лабораторна робота №3, етап 4. Бартошко О.І., КІ-408, варіант 1.
#
# Маршрут (відкриті САПР):
#   1. GHDL      : VHDL-2008 -> Verilog-netlist (ghdl synth --out=verilog)
#   2. Yosys     : synth_ice40 -> технологічне відображення (SB_LUT4, SB_DFF*, SB_CARRY)
#   3. nextpnr   : розміщення і трасування, статичний часовий аналіз, Fmax
#   4. icepack   : бітстрім (.bin)
#   5. icetime   : незалежна оцінка критичного шляху (IceStorm timing)
#   6. GHDL      : пост-синтезна симуляція netlist uart_top тим самим тестбенчем
#
# Звіти: synth/reports/   Проміжні файли: synth/out/ (не комітяться)
# Параметри: CLK_FREQ (Гц), BAUD, FREQ_MHZ (часове обмеження), SEED
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYN="$ROOT/synth"
OUT="$SYN/out"
REP="$SYN/reports"
mkdir -p "$OUT" "$REP"

CLK_FREQ="${CLK_FREQ:-50000000}"
BAUD="${BAUD:-115200}"
FREQ_MHZ="${FREQ_MHZ:-50}"
SEED="${SEED:-1}"
DEVICE="hx8k"
PACKAGE="ct256"
PCF="$SYN/uart_hx8k.pcf"
TOP="uart_echo_top"

RTL=(
  "$ROOT/rtl/baud_gen.vhd"
  "$ROOT/rtl/uart_tx.vhd"
  "$ROOT/rtl/uart_rx.vhd"
  "$ROOT/rtl/uart_top.vhd"
  "$SYN/uart_echo_top.vhd"
)
GF=(--std=08 --workdir="$OUT")

echo "[1/6] GHDL: VHDL -> Verilog"
rm -f "$OUT"/work-obj08.cf
ghdl -a "${GF[@]}" "${RTL[@]}"
ghdl synth "${GF[@]}" -gCLK_FREQ="$CLK_FREQ" -gBAUD="$BAUD" --out=verilog "$TOP" > "$OUT/$TOP.v"
ghdl synth "${GF[@]}" -gCLK_FREQ="$CLK_FREQ" -gBAUD="$BAUD" --out=verilog uart_top > "$OUT/uart_top.v"

echo "[2/6] Yosys: synth_ice40"
# 2a. Ядро uart_top з ієрархією (ресурси по модулях)
yosys -q -l "$REP/yosys_uart_top_hier.log" -p "
  read_verilog $OUT/uart_top.v;
  synth_ice40 -top uart_top -noflatten;
  tee -o $REP/yosys_stat_uart_top_hier.txt stat" >/dev/null
# 2b. Ядро uart_top, плоский netlist
yosys -q -l "$REP/yosys_uart_top.log" -p "
  read_verilog $OUT/uart_top.v;
  synth_ice40 -top uart_top;
  tee -o $REP/yosys_stat_uart_top.txt stat" >/dev/null
# 2c. Верхній рівень для плати (echo) -> JSON для nextpnr
yosys -q -l "$REP/yosys_$TOP.log" -p "
  read_verilog $OUT/$TOP.v;
  synth_ice40 -top $TOP -json $OUT/$TOP.json;
  tee -o $REP/yosys_stat_$TOP.txt stat" >/dev/null

echo "[3/6] nextpnr-ice40: place & route, timing @ ${FREQ_MHZ} MHz"
nextpnr-ice40 --"$DEVICE" --package "$PACKAGE" --pcf "$PCF" \
  --json "$OUT/$TOP.json" --asc "$OUT/$TOP.asc" \
  --freq "$FREQ_MHZ" --seed "$SEED" \
  --report "$REP/nextpnr_report.json" \
  --log "$REP/nextpnr.log" >/dev/null 2>&1

echo "[4/6] icepack: bitstream"
icepack "$OUT/$TOP.asc" "$OUT/$TOP.bin"

echo "[5/6] icetime: timing analysis"
# Пошук chipdb (Homebrew кладе його у Cellar, Linux — у /usr/(local/)share)
CHIPDB=""
for d in "${ICESTORM_CHIPDB_DIR:-}" \
         "$(command -v brew >/dev/null && brew --prefix icestorm 2>/dev/null)/share/icestorm/chipdb" \
         "$(command -v brew >/dev/null && brew --prefix icestorm 2>/dev/null)/share/icestorm" \
         /usr/local/share/icestorm /usr/share/icestorm; do
  if [[ -n "$d" && -f "$d/chipdb-8k.txt" ]]; then CHIPDB="$d/chipdb-8k.txt"; break; fi
done
icetime -d "$DEVICE" -P "$PACKAGE" -p "$PCF" -c "$FREQ_MHZ" -t ${CHIPDB:+-C "$CHIPDB"} \
  -r "$REP/icetime.txt" "$OUT/$TOP.asc" > "$REP/icetime_stdout.txt" 2>&1 || true

echo "[6/6] Пост-синтезна симуляція: netlist GHDL (uart_top) + tb_uart"
# Netlist після синтезу GHDL (--out=vhdl) перевіряється тим самим тестбенчем.
PS="$OUT/postsynth"
rm -rf "$PS" && mkdir -p "$PS"
ghdl synth "${GF[@]}" -gCLK_FREQ="$CLK_FREQ" -gBAUD="$BAUD" --out=vhdl uart_top > "$PS/uart_top_syn.vhd"
if [[ "$(uname)" == "Darwin" ]]; then
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$(sw_vers -productVersion | cut -d. -f1).0}"
fi
( cd "$PS" && ghdl -a --std=08 --workdir="$PS" "$PS/uart_top_syn.vhd" "$ROOT/tb/tb_uart.vhd" \
    && ghdl -e --std=08 --workdir="$PS" tb_uart \
    && ghdl -r --std=08 --workdir="$PS" tb_uart -gG_CLK_FREQ="$CLK_FREQ" -gG_BAUD="$BAUD" \
         --ieee-asserts=disable-at-0 --stop-time=20ms ) > "$REP/postsynth_sim_log.txt" 2>&1 || true

# --- Короткий підсумок ---
{
  echo "=== Підсумок синтезу: $TOP (iCE40 HX8K ${PACKAGE}), CLK_FREQ=$CLK_FREQ, BAUD=$BAUD ==="
  echo "Інструменти: $(ghdl --version | head -1 | cut -d'(' -f1)| $(yosys -V | cut -d'(' -f1)| nextpnr-ice40 $(command -v brew >/dev/null && brew list --versions nextpnr-ice40 2>/dev/null | awk '{print $2}')"
  echo
  echo "--- Yosys stat (uart_top, ядро) ---"
  grep -E " cells$|SB_" "$REP/yosys_stat_uart_top.txt" || true
  echo
  echo "--- Yosys stat ($TOP) ---"
  grep -E " cells$|SB_" "$REP/yosys_stat_$TOP.txt" || true
  echo
  echo "--- nextpnr: використання пристрою ---"
  grep -A7 "Device utilisation" "$REP/nextpnr.log" | head -8
  echo
  echo "--- nextpnr: часовий аналіз ---"
  echo "(перший рядок — оцінка до трасування, останній — після трасування)"
  grep -E "Max frequency|Max delay" "$REP/nextpnr.log" || true
  echo
  echo "--- icetime ---"
  grep -hE "Total number of logic levels|Total path delay|Timing estimate" "$REP/icetime_stdout.txt" "$REP/icetime.txt" 2>/dev/null | sort -u || true
  echo
  echo "--- Пост-синтезна симуляція (netlist uart_top) ---"
  grep -E "SUMMARY|TEST PASSED|failure" "$REP/postsynth_sim_log.txt" | sed 's#^.*/tb/##' || echo "НЕ ПРОЙДЕНО"
} | tee "$REP/summary.txt"
