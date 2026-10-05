# TangNanoGPU gateware - open-source flow for the Tang Nano 20K (GW2AR-18C):
#   yosys (synth_gowin) -> fix_bram_oce.py -> nextpnr-himbaechel -> gowin_pack
#   -> openFPGALoader
#
# Requirements (see ../docs/building.md):
#   - yosys >= 0.33, nextpnr-himbaechel with the Gowin backend
#   - Apicula (gowin_pack) >= 0.34: 0.33 crashes packing the second PLL
#     (GW2A get_pll_bels bug, fixed upstream). If your system gowin_pack is
#     older, point GOWIN_PACK at a newer one, e.g. from a venv:
#         python3 -m venv ~/apycula && ~/apycula/bin/pip install apycula
#         make GOWIN_PACK=~/apycula/bin/gowin_pack
#   - iverilog for `make sim`
#
# Targets:
#   make sim        RTL regression (unit testbenches + full-chip self test)
#   make golden     pixel-exact comparison against TinyGPU (needs cmake/g++)
#   make bitstream  build/top_tangnano20k.fs
#   make load       load into SRAM (volatile)    make flash   write to flash

TOP        := top_tangnano20k
DEVICE     := GW2AR-LV18QN88C8/I7
FAMILY     := GW2A-18C
YOSYS      ?= yosys
NEXTPNR    ?= nextpnr-himbaechel
GOWIN_PACK ?= gowin_pack
LOADER     ?= openFPGALoader
PYTHON     ?= python3

RTL := rtl/top_tangnano20k.v rtl/clocks.v rtl/spi_gpu.v rtl/byte_fifo.v \
       rtl/bram_sdp.v rtl/gpu_exec.v rtl/scanout.v rtl/video_timing.v \
       rtl/sdram_ctrl.v rtl/dvi_tx.v rtl/tmds_encoder.v
CST   := constraints/tangnano20k.cst
BUILD := build

.PHONY: all sim golden synth pnr bitstream load flash clean

all: bitstream

sim:
	./tb/run_regression.sh

golden:
	../tools/golden/run_golden.sh

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/$(TOP).json: $(RTL) | $(BUILD)
	$(YOSYS) -q -l $(BUILD)/synth.log -p "read_verilog -sv $(RTL); synth_gowin -top $(TOP); simplemap t:\$$buf; opt_clean; write_json $@"
	$(PYTHON) tools/fix_bram_oce.py $@

$(BUILD)/$(TOP)_pnr.json: $(BUILD)/$(TOP).json $(CST)
	$(NEXTPNR) --json $< --write $@ --device $(DEVICE) --vopt family=$(FAMILY) \
		--vopt cst=$(CST) --report $(BUILD)/$(TOP)_report.json -l $(BUILD)/pnr.log

$(BUILD)/$(TOP).fs: $(BUILD)/$(TOP)_pnr.json
	$(GOWIN_PACK) -d $(FAMILY) -o $@ $<
	@grep -E "LUT4:|BSRAM:|rPLL:|Max frequency" $(BUILD)/pnr.log | tail -8

synth: $(BUILD)/$(TOP).json
pnr: $(BUILD)/$(TOP)_pnr.json
bitstream: $(BUILD)/$(TOP).fs

load: $(BUILD)/$(TOP).fs
	$(LOADER) -b tangnano20k $<

flash: $(BUILD)/$(TOP).fs
	$(LOADER) -b tangnano20k -f $<

clean:
	rm -rf $(BUILD)/sim $(BUILD)/*.json $(BUILD)/*.log
