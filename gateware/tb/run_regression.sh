#!/usr/bin/env bash
# RTL regression for TangNanoGPU (Icarus Verilog). Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/sim

RTL="rtl/top_tangnano20k.v rtl/clocks.v rtl/spi_gpu.v rtl/async_fifo.v rtl/byte_fifo.v rtl/bram_sdp.v
     rtl/gpu_exec.v rtl/scanout.v rtl/video_timing.v rtl/sdram_ctrl.v rtl/dvi_tx.v
     rtl/tmds_encoder.v"

fail=0
run() {  # name, vvp args, sources...
  local name=$1 args=$2; shift 2
  iverilog -g2012 -DSIMULATION -o "build/sim/$name" "$@"
  local out
  out=$(vvp -n "build/sim/$name" $args | grep -E "^(PASS|FAIL)" || true)
  echo "$out"
  [[ "$out" == PASS* ]] || fail=1
}

run tb_tmds         ""          tb/tb_tmds.v rtl/tmds_encoder.v
run tb_video_timing ""          tb/tb_video_timing.v rtl/video_timing.v
run tb_sdram_ctrl   ""          tb/tb_sdram_ctrl.v tb/sdram_model.v rtl/sdram_ctrl.v
# video output content, separate system/pixel clocks (~1.5 min each)
SCAN="tb/tb_scanout.v tb/sdram_model.v rtl/scanout.v rtl/video_timing.v rtl/bram_sdp.v rtl/sdram_ctrl.v"
run tb_scanout_hdmi ""          $SCAN
run tb_scanout_lcd  ""          -DLCD $SCAN
# full chip over its SPI pins: SPI at 10.8MHz, SPI at ~42MHz, quad SPI at ~42MHz
run tb_top_spi10    "+selftest"                    tb/tb_top.v tb/sdram_model.v $RTL
run tb_top_spi42    "+selftest +sckns=12"          tb/tb_top.v tb/sdram_model.v $RTL
run tb_top_qspi42   "+selftest +sckns=12 +quad"    tb/tb_top.v tb/sdram_model.v $RTL
# real 200us SDRAM power-up wait (catches start-up effects like a stuck
# "scanout late" flag, which the shortened 2us simulation wait hides)
run tb_top_init200  "+selftest" -DTB_INIT_US=200   tb/tb_top.v tb/sdram_model.v $RTL
# LCD build (RGB panel instead of HDMI, MCU link on other pins)
run tb_top_lcd      "+selftest +sckns=12 +quad" -DDISPLAY_LCD tb/tb_top.v tb/sdram_model.v $RTL

if [[ $fail -ne 0 ]]; then
  echo "REGRESSION FAILED"
  exit 1
fi
echo "ALL PASS"
