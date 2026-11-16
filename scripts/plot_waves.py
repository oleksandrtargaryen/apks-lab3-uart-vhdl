#!/usr/bin/env python3
"""
plot_waves.py — побудова осцилограм (часових діаграм) UART з VCD-файлу GHDL.

Лабораторна робота №3, Бартошко О.І., КІ-408, варіант 1 (UART / VHDL).

Читає build/uart.vcd (створюється sim/run_sim.sh) і рендерить у docs/img/:
  * wave_overview.png     — уся симуляція: три фази тесту (Tx, Rx, loopback);
  * wave_clk_divider.png  — CLK 50 МГц та дільник baud_gen (tick кожні 27 тактів);
  * wave_tx_0x55.png      — один повний кадр передавача з байтом 0x55;
  * wave_rx_0x3C.png      — прийом байта 0x3C від зовнішнього пристрою;
  * wave_rx_frame_err.png — кадр із помилковим стоп-бітом (rx_frame_err);
  * wave_loopback.png     — петльовий тест TXD -> RXD (байт 0xA3).

Використання:
  python3 scripts/plot_waves.py [build/uart.vcd] [docs/img]
Потрібен лише matplotlib (парсер VCD — власний, без зовнішніх залежностей).
"""
from __future__ import annotations

import bisect
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Polygon  # noqa: E402

FS_PER_US = 1_000_000_000  # VCD від GHDL має timescale 1 fs

# --- Кольори (стримана палітра: одна основна, акцент лише для маркерів) ---
INK = "#1f2328"          # текст
MUTED = "#6e7781"        # допоміжний текст, сітка
GRID = "#d0d7de"
WAVE = "#1f5fbf"         # лінії однобітових сигналів
WAVE_FILL = "#1f5fbf22"
BUS_EDGE = "#4b5563"
BUS_FILL = "#eef2f7"
KEY = "#0b7a75"          # ключові послідовні лінії (TXD/RXD)
MARK = "#c2410c"         # моменти вибірки / події

TX_STATES = {0: "IDLE", 1: "START", 2: "DATA", 3: "STOP"}


# =============================================================================
# Парсер VCD
# =============================================================================
class Signal:
    def __init__(self, name: str, width: int, kind: str):
        self.name = name
        self.width = width
        self.kind = kind
        self.times: list[int] = []
        self.values: list[str] = []

    def add(self, t: int, v: str) -> None:
        if self.times and self.times[-1] == t:
            self.values[-1] = v          # кілька змін у дельта-циклах — беремо останню
        else:
            self.times.append(t)
            self.values.append(v)

    def at(self, t: int) -> str:
        i = bisect.bisect_right(self.times, t) - 1
        return self.values[max(i, 0)]

    def ival(self, t: int) -> int | None:
        return to_int(self.at(t))

    def segments(self, t0: int, t1: int):
        """Список (початок, кінець, значення) у вікні [t0, t1]."""
        i = max(bisect.bisect_right(self.times, t0) - 1, 0)
        out = []
        while i < len(self.times) and self.times[i] < t1:
            s = max(self.times[i], t0)
            e = self.times[i + 1] if i + 1 < len(self.times) else t1
            out.append((s, min(e, t1), self.values[i]))
            i += 1
        return out

    def edges(self, frm: str, to: str, t0: int = 0, t1: int | None = None):
        res = []
        for i in range(1, len(self.times)):
            t = self.times[i]
            if t < t0 or (t1 is not None and t > t1):
                continue
            if self.values[i - 1] == frm and self.values[i] == to:
                res.append(t)
        return res


def to_int(v: str) -> int | None:
    try:
        return int(v, 2)
    except ValueError:
        return None


def parse_vcd(path: Path) -> tuple[dict[str, Signal], int]:
    by_id: dict[str, list[Signal]] = {}
    sigs: dict[str, Signal] = {}
    scope: list[str] = []
    t = 0
    t_end = 0
    with open(path, "r", encoding="latin-1") as f:
        in_defs = True
        for line in f:
            line = line.strip()
            if not line:
                continue
            if in_defs:
                tok = line.split()
                if tok[0] == "$scope":
                    scope.append(tok[2])
                elif tok[0] == "$upscope":
                    scope.pop()
                elif tok[0] == "$var":
                    kind, width, ident, name = tok[1], int(tok[2]), tok[3], tok[4]
                    name = name.split("[")[0]
                    full = ".".join(scope + [name])
                    s = Signal(full, width, kind)
                    sigs[full] = s
                    by_id.setdefault(ident, []).append(s)
                elif tok[0] == "$enddefinitions":
                    in_defs = False
                continue
            c = line[0]
            if c == "#":
                t = int(line[1:])
                t_end = t
            elif c in "01xzuUXZWLH-":
                for s in by_id.get(line[1:], []):
                    s.add(t, c)
            elif c in "bB":
                val, ident = line[1:].split()
                for s in by_id.get(ident, []):
                    s.add(t, val)
            elif c in "rR":
                pass
    return sigs, t_end


# =============================================================================
# Рисування часових діаграм
# =============================================================================
class Row:
    """Опис рядка діаграми."""

    def __init__(self, sig: Signal, label: str, kind: str = "bit",
                 fmt=None, color: str = WAVE, bold: bool = False):
        self.sig, self.label, self.kind = sig, label, kind
        self.fmt = fmt or (lambda v: v)
        self.color, self.bold = color, bold


def hexfmt(v: str) -> str:
    n = to_int(v)
    return "?" if n is None else f"0x{n:02X}"


def decfmt(v: str) -> str:
    n = to_int(v)
    return "?" if n is None else str(n)


def statefmt(v: str) -> str:
    n = to_int(v)
    return TX_STATES.get(n, "?") if n is not None else "?"


def us(t: int) -> float:
    return t / FS_PER_US


def draw(rows: list[Row], t0: int, t1: int, title: str, out: Path,
         width: float = 14.0, annot=None, xunit: str = "мкс") -> None:
    n = len(rows)
    row_h = 0.62
    fig_h = 1.25 + n * row_h
    fig, ax = plt.subplots(figsize=(width, fig_h), dpi=150)
    fig.patch.set_facecolor("white")
    ax.set_facecolor("white")

    x0, x1 = us(t0), us(t1)
    span = x1 - x0
    # Ширина символу у одиницях осі X (для рішення, чи вміщується підпис)
    char_w = span / (width * 0.82 * 150 / 6.2) * 1.15

    for k, row in enumerate(rows):
        base = (n - 1 - k) * 1.0
        hi = base + 0.7
        ax.axhline(base - 0.15, color="#f0f2f4", lw=0.6, zorder=0)
        segs = row.sig.segments(t0, t1)
        if row.kind == "bit":
            xs, ys = [], []
            for s, e, v in segs:
                y = hi if v == "1" else base
                xs += [us(s), us(e)]
                ys += [y, y]
            ax.plot(xs, ys, color=row.color, lw=1.4 if row.bold else 1.1,
                    solid_joinstyle="miter", zorder=3)
            ax.fill_between(xs, base, ys, color=row.color, alpha=0.10, lw=0,
                            zorder=2)
        else:  # шина / ціле / стан
            slant = min(span * 0.0025, 0.4 * min((us(e) - us(s)) for s, e, _ in segs)) if segs else 0
            for s, e, v in segs:
                xs_, xe_ = us(s), us(e)
                sl = min(slant, (xe_ - xs_) / 3)
                mid = base + 0.35
                poly = [(xs_, mid), (xs_ + sl, hi), (xe_ - sl, hi), (xe_, mid),
                        (xe_ - sl, base), (xs_ + sl, base)]
                ax.add_patch(Polygon(poly, closed=True, facecolor=BUS_FILL,
                                     edgecolor=BUS_EDGE, lw=0.8, zorder=2))
                txt = row.fmt(v)
                if (xe_ - xs_) > (len(txt) + 1) * char_w:
                    ax.text((xs_ + xe_) / 2, mid, txt, ha="center", va="center",
                            fontsize=7.5, color=INK, zorder=4,
                            family="DejaVu Sans Mono")

    ax.set_yticks([(n - 1 - k) + 0.35 for k in range(n)])
    ax.set_yticklabels([r.label for r in rows], fontsize=9, color=INK)
    for lbl, r in zip(ax.get_yticklabels(), rows):
        if r.bold:
            lbl.set_fontweight("bold")
    ax.tick_params(axis="y", length=0)
    ax.set_xlim(x0, x1)
    ax.set_ylim(-0.45, n - 0.1 + (0.55 if annot else 0))
    ax.set_xlabel(f"час, {xunit}", fontsize=9, color=MUTED)
    ax.tick_params(axis="x", labelsize=8, colors=MUTED)
    ax.grid(axis="x", color=GRID, lw=0.5, ls=":")
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    ax.set_title(title, fontsize=11, color=INK, loc="left", pad=8)
    if annot:
        annot(ax, n)
    fig.tight_layout()
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, facecolor="white")
    plt.close(fig)
    print(f"  -> {out}")


def bit_grid(t_start: int, t_bit: int, top_y: float, values: list[str] | None = None):
    """Анотація меж бітів кадру 8N1 та підписів START/D0..D7/STOP."""
    names = ["START"] + [f"D{i}" for i in range(8)] + ["STOP"]

    def _annot(ax, n):
        for i in range(11):
            x = us(t_start + i * t_bit)
            ax.axvline(x, color=MUTED, lw=0.6, ls="--", zorder=1, alpha=0.7)
        for i, nm in enumerate(names):
            xm = us(t_start + i * t_bit + t_bit // 2)
            lab = nm if values is None else f"{nm}\n{values[i]}"
            ax.text(xm, top_y, lab, ha="center", va="bottom", fontsize=7.5,
                    color=INK if values is None else KEY, linespacing=1.0)
    return _annot


# =============================================================================
# Побудова конкретних діаграм
# =============================================================================
def main() -> int:
    root = Path(__file__).resolve().parents[1]
    vcd = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "build" / "uart.vcd"
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else root / "docs" / "img"
    print(f"Читання {vcd} ...")
    S, t_end = parse_vcd(vcd)

    def g(name: str) -> Signal:
        return S["tb_uart." + name]

    clk, rst = g("clk"), g("rst")
    tick = g("dut.tick")
    txd, rxd_ext, rxd = g("uart_txd"), g("ext_rxd"), g("uart_rxd")

    # Період біта: 16 періодів tick
    ticks = tick.edges("0", "1")
    t_tick = ticks[2] - ticks[1]
    t_bit = 16 * t_tick
    t_clk = clk.edges("0", "1")[2] - clk.edges("0", "1")[1]
    print(f"  T_clk = {t_clk / 1e6:.1f} нс, T_tick = {t_tick / 1e6:.1f} нс, "
          f"T_bit = {t_bit / 1e9:.3f} мкс")

    # Початки кадрів визначаємо за входом FSM у стан START (код "01"),
    # а не за будь-яким спадом лінії (спади бувають і всередині даних).
    tx_frames = [t for t in g("dut.u_tx.state_dbg").edges("00", "01")]
    rx_enter = [t for t in g("dut.u_rx.state_dbg").edges("00", "01")]

    def line_start(line: Signal, t_fsm: int) -> int:
        return max(e for e in line.edges("1", "0") if e <= t_fsm)

    # ---------------- 1. Огляд усієї симуляції ----------------
    loop_on = g("loopback").edges("0", "1")[0]
    ph2 = rxd_ext.edges("1", "0")[0]
    valid_t = g("rx_valid").edges("0", "1")
    fe_t = g("rx_frame_err").edges("0", "1")

    def overview_annot(ax, n):
        ymax = n - 0.1 + 0.15
        for xs, xe, name in ((0, ph2 - t_bit, "Фаза 1: передавач (0x55, 0xA3, 0x00, 0xFF)"),
                             (ph2 - t_bit, loop_on, "Фаза 2: приймач (зовнішній пристрій)"),
                             (loop_on, t_end, "Фаза 3: loopback TXD→RXD")):
            ax.axvline(us(xs), color=MUTED, lw=0.8, ls="--", zorder=1)
            ax.text(us(xs) + 5, ymax, name, fontsize=8.5, color=INK, va="bottom")
        yv = 3 + 0.85  # над рядком rx_valid
        for t in valid_t:
            ax.plot(us(t), n - 1 - 9 + 0.7, "v", color=MARK, ms=4, zorder=5)
        for t in fe_t:
            ax.text(us(t) + 6, n - 1 - 11 + 0.35, "← помилка кадру (0x7E, стоп-біт = 0)",
                    fontsize=7.5, color=MARK, ha="left", va="center")
        _ = yv

    rows = [
        Row(rst, "RESET"),
        Row(g("tx_start"), "tx_start"),
        Row(g("tx_data"), "tx_data", "bus", hexfmt),
        Row(txd, "TXD (uart_txd)", color=KEY, bold=True),
        Row(g("tx_busy"), "tx_busy"),
        Row(g("tx_done"), "tx_done"),
        Row(g("loopback"), "loopback"),
        Row(rxd_ext, "ext_rxd (зовн. пристрій)"),
        Row(rxd, "RXD (uart_rxd)", color=KEY, bold=True),
        Row(g("rx_valid"), "rx_valid"),
        Row(g("rx_data"), "rx_data", "bus", hexfmt),
        Row(g("rx_frame_err"), "rx_frame_err"),
    ]
    draw(rows, 0, t_end, "UART: огляд симуляції (CLK 50 МГц, 115200 бод, 8N1)",
         out_dir / "wave_overview.png", width=16, annot=overview_annot)

    # ---------------- 2. CLK і дільник baud_gen ----------------
    tk = ticks[3]
    t0c, t1c = tk - 4 * t_clk, tk + 2 * t_tick + 4 * t_clk
    rows = [
        Row(clk, "CLK 50 МГц", bold=True),
        Row(rst, "RESET"),
        Row(g("dut.u_baud.cnt"), "baud_gen.cnt", "bus", decfmt),
        Row(tick, "tick (x16, 1.85 МГц)", color=KEY, bold=True),
        Row(g("dut.u_tx.tick_cnt"), "uart_tx.tick_cnt", "bus", decfmt),
    ]
    draw(rows, t0c, t1c,
         f"Дільник частоти baud_gen: tick кожні {t_tick // t_clk} тактів CLK "
         f"(період {t_tick / 1e6:.0f} нс)",
         out_dir / "wave_clk_divider.png", width=16)

    # ---------------- 3. Кадр передавача 0x55 ----------------
    ts = tx_frames[0]
    t0, t1 = max(0, ts - int(1.2 * t_bit)), ts + int(11.3 * t_bit)
    vals = [txd.at(ts + i * t_bit + t_bit // 2) for i in range(10)]
    rows = [
        Row(tick, "tick (x16)"),
        Row(g("tx_start"), "tx_start"),
        Row(g("tx_data"), "tx_data", "bus", hexfmt),
        Row(g("dut.u_tx.state_dbg"), "стан FSM Tx", "bus", statefmt),
        Row(g("dut.u_tx.bit_idx"), "bit_idx", "bus", decfmt),
        Row(g("dut.u_tx.shreg"), "shreg", "bus", hexfmt),
        Row(txd, "TXD", color=KEY, bold=True),
        Row(g("tx_busy"), "tx_busy"),
        Row(g("tx_done"), "tx_done"),
    ]
    draw(rows, t0, t1,
         "Передавач: кадр 8N1 байта 0x55 = 0b01010101 (LSB first: 1,0,1,0,1,0,1,0), "
         f"T_bit = {t_bit / 1e9:.2f} мкс",
         out_dir / "wave_tx_0x55.png", annot=bit_grid(ts, t_bit, len(rows) - 0.25, vals))

    # ---------------- 4. Прийом байта 0x3C ----------------
    rs = line_start(rxd_ext, [t for t in rx_enter if t > ph2][0])
    t0, t1 = rs - int(1.0 * t_bit), rs + int(11.0 * t_bit)
    sync = g("dut.u_rx.rx_sync")
    samples = g("dut.u_rx.sample_dbg").edges("0", "1", t0, t1)
    rx_rows = [
        Row(tick, "tick (x16)"),
        Row(rxd, "RXD (вхід)", color=KEY, bold=True),
        Row(sync, "rx_sync (2-FF)"),
        Row(g("dut.u_rx.state_dbg"), "стан FSM Rx", "bus", statefmt),
        Row(g("dut.u_rx.sample_dbg"), "вибірка (sample)", color=MARK),
        Row(g("dut.u_rx.bit_idx"), "bit_idx", "bus", decfmt),
        Row(g("dut.u_rx.shreg"), "shreg", "bus", hexfmt),
        Row(g("rx_data"), "rx_data", "bus", hexfmt),
        Row(g("rx_valid"), "rx_valid", bold=True),
    ]

    def rx_annot_factory(samples_, rs_, nrows, t0_, t1_):
        names = ["START"] + [f"D{i}" for i in range(8)] + ["STOP"]

        def _a(ax, n):
            bit_grid(rs_, t_bit, n - 0.25)(ax, n)
            y_sync = n - 1 - 2  # рядок rx_sync
            for i, t in enumerate(samples_[:10]):
                # вибірка робиться на фронті, коли sample_dbg ще 0 -> значення rx_sync
                v = sync.at(t - 1)
                y = y_sync + (0.7 if v == "1" else 0.0)
                ax.plot(us(t), y, "o", color=MARK, ms=4.5, zorder=6)
                ax.axvline(us(t), color=MARK, lw=0.5, alpha=0.35, zorder=1)
                ax.text(us(t) + (us(t1_) - us(t0_)) * 0.004, y + 0.08, v,
                        ha="left", va="bottom", fontsize=7.5,
                        color=MARK, fontweight="bold", zorder=6)
            _ = names
        return _a

    draw(rx_rows, t0, t1,
         "Приймач: байт 0x3C = 0b00111100 від зовнішнього пристрою; "
         "вибірка в середині кожного біта (x16)",
         out_dir / "wave_rx_0x3C.png",
         annot=rx_annot_factory(samples, rs, len(rx_rows), t0, t1))

    # ---------------- 5. Помилка кадру ----------------
    fe = fe_t[0]
    rs_fe = line_start(rxd_ext, max(t for t in rx_enter if t < fe))
    t0, t1 = rs_fe - int(1.0 * t_bit), rs_fe + int(11.5 * t_bit)
    samples = g("dut.u_rx.sample_dbg").edges("0", "1", t0, t1)
    fe_rows = rx_rows[:-2] + [Row(g("rx_valid"), "rx_valid"),
                              Row(g("rx_frame_err"), "rx_frame_err", color=MARK, bold=True)]
    draw(fe_rows, t0, t1,
         "Приймач: кадр 0x7E зі стоп-бітом '0' -> rx_frame_err, rx_valid не формується",
         out_dir / "wave_rx_frame_err.png",
         annot=rx_annot_factory(samples, rs_fe, len(fe_rows), t0, t1))

    # ---------------- 6. Loopback ----------------
    lb = [t for t in tx_frames if t > loop_on]
    ts = lb[1]   # другий байт петлі (0xA3)
    t0, t1 = ts - int(1.0 * t_bit), ts + int(11.5 * t_bit)
    rows = [
        Row(g("tx_data"), "tx_data", "bus", hexfmt),
        Row(txd, "TXD", color=KEY, bold=True),
        Row(g("tx_busy"), "tx_busy"),
        Row(rxd, "RXD = TXD (петля)", color=KEY, bold=True),
        Row(g("dut.u_rx.state_dbg"), "стан FSM Rx", "bus", statefmt),
        Row(g("dut.u_rx.sample_dbg"), "вибірка (sample)", color=MARK),
        Row(g("rx_data"), "rx_data", "bus", hexfmt),
        Row(g("rx_valid"), "rx_valid", bold=True),
        Row(g("tx_done"), "tx_done"),
    ]
    draw(rows, t0, t1, "Петльовий тест: передано 0xA3 через TXD, прийнято 0xA3 на RXD",
         out_dir / "wave_loopback.png",
         annot=bit_grid(ts, t_bit, len(rows) - 0.25))
    print("Готово.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
