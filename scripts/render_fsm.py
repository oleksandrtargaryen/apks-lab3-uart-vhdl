#!/usr/bin/env python3
"""
render_fsm.py — рендер діаграм станів (FSM) передавача та приймача UART у PNG.

Лабораторна робота №3, Бартошко О.І., КІ-408, варіант 1 (UART / VHDL).

Генерує опис графів мовою DOT і викликає утиліту Graphviz `dot`.
Результат: docs/img/fsm_tx.png, docs/img/fsm_rx.png
(текстовий варіант тих самих діаграм у Mermaid — docs/fsm.md).

Використання: python3 scripts/render_fsm.py [docs/img]
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

COMMON = """
  graph [rankdir=LR, fontname="Helvetica", fontsize=13, labelloc=t, pad=0.3,
         nodesep=0.6, ranksep=1.0, bgcolor=white];
  node  [shape=circle, style="filled", fillcolor="#eef2f7", color="#1f5fbf",
         penwidth=1.6, fontname="Helvetica-Bold", fontsize=12, fixedsize=true,
         width=1.15];
  edge  [fontname="Helvetica", fontsize=10, color="#4b5563", fontcolor="#1f2328",
         arrowsize=0.8];
  __init [shape=point, width=0.12, color="#1f2328", fillcolor="#1f2328"];
"""

TX_DOT = """digraph uart_tx_fsm {
%s
  label=<<b>FSM передавача UART (uart_tx), кадр 8N1</b><br/><font point-size="10">tick — імпульс x16 від baud_gen; 1 біт = 16 tick; вихід TXD у вузлі</font>>;
  IDLE  [label="IDLE\\nTXD=1", shape=doublecircle, width=1.05];
  START [label="START\\nTXD=0"];
  DATA  [label="DATA\\nTXD=shreg(0)", width=1.45];
  STOP  [label="STOP\\nTXD=1"];

  __init -> IDLE [label="rst"];
  IDLE  -> IDLE  [label="tx_start=0\\n(або запит прийнято,\\nчекаємо tick)"];
  IDLE  -> START [label="pending=1 ∧ tick\\n(shreg←tx_data, tx_busy=1)"];
  START -> START [label="tick_cnt<15"];
  START -> DATA  [label="16 tick\\n(bit_idx←0)"];
  DATA  -> DATA  [label="16 tick ∧ bit_idx<7\\n(shreg>>1, bit_idx+1)"];
  DATA  -> STOP  [label="16 tick ∧ bit_idx=7"];
  STOP  -> STOP  [label="tick_cnt<15"];
  STOP  -> IDLE  [label="16 tick\\n(tx_done=1, tx_busy=0)"];
}
""" % COMMON

RX_DOT = """digraph uart_rx_fsm {
%s
  label=<<b>FSM приймача UART (uart_rx), 16x передискретизація</b><br/><font point-size="10">rx_sync — вхід після 2-FF синхронізатора; вибірка в середині біта</font>>;
  IDLE  [label="IDLE", shape=doublecircle, width=1.05];
  START [label="START"];
  DATA  [label="DATA"];
  STOP  [label="STOP"];

  __init -> IDLE [label="rst"];
  IDLE  -> IDLE  [label="немає спаду"];
  IDLE  -> START [label="спад 1→0\\n(rx_prev=1 ∧ rx_sync=0)"];
  START -> START [label="tick_cnt<7"];
  START -> IDLE  [label="8 tick ∧ rx_sync=1\\n(завада, хибний старт)", color="#c2410c", fontcolor="#c2410c"];
  START -> DATA  [label="8 tick ∧ rx_sync=0\\n(середина старт-біта)"];
  DATA  -> DATA  [label="16 tick ∧ bit_idx<7\\n(shreg←rx_sync&shreg>>1)"];
  DATA  -> STOP  [label="16 tick ∧ bit_idx=7"];
  STOP  -> STOP  [label="tick_cnt<15"];
  STOP  -> IDLE  [label="16 tick ∧ rx_sync=1\\n(rx_data←shreg, rx_valid=1)"];
  STOP  -> IDLE  [label="16 tick ∧ rx_sync=0\\n(rx_frame_err=1)", color="#c2410c", fontcolor="#c2410c"];
}
""" % COMMON


def render(dot_src: str, out: Path) -> None:
    dot = shutil.which("dot")
    if dot is None:
        raise SystemExit("Graphviz 'dot' не знайдено (brew install graphviz / apt install graphviz)")
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([dot, "-Tpng", "-Gdpi=160", "-o", str(out)],
                   input=dot_src.encode("utf-8"), check=True)
    print(f"  -> {out}")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "docs" / "img"
    render(TX_DOT, out_dir / "fsm_tx.png")
    render(RX_DOT, out_dir / "fsm_rx.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
