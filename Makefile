# Makefile — лабораторна робота №3 (UART / VHDL), Бартошко О.І., КІ-408
#
#   make sim       — симуляція з реальними параметрами (50 МГц, 115200 бод) + VCD
#   make sim-fast  — швидка симуляція (781250 бод, DIVISOR = 4)
#   make waves     — PNG-осцилограми з build/uart.vcd у docs/img/ (потрібен matplotlib)
#   make fsm       — PNG-діаграми станів у docs/img/ (потрібен Graphviz)
#   make synth     — синтез для Lattice iCE40 HX8K (Yosys + nextpnr), звіти в synth/reports/
#   make gtkwave   — відкрити осцилограми у GTKWave
#   make clean     — видалити артефакти збирання

PYTHON ?= python3

.PHONY: all sim sim-fast waves fsm synth gtkwave clean

all: sim

sim:
	./sim/run_sim.sh

sim-fast:
	FAST=1 ./sim/run_sim.sh

waves: build/uart.vcd
	$(PYTHON) scripts/plot_waves.py build/uart.vcd docs/img

build/uart.vcd:
	./sim/run_sim.sh

fsm:
	$(PYTHON) scripts/render_fsm.py docs/img

synth:
	@test -x synth/run_synth.sh || { echo "Скрипт синтезу synth/run_synth.sh відсутній (етап 4: гілка feature/develop/4-synthesis)"; exit 1; }
	./synth/run_synth.sh

gtkwave: build/uart.vcd
	gtkwave build/uart.vcd &

clean:
	rm -rf build synth/out
