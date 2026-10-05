#!/usr/bin/env bash
# Golden-model test: the RTL must render the test scene (golden.cpp)
# pixel-identically to TinyGPU's software Surface<RGB565>.
#
#   1. build + run tools/golden/golden   -> expected.hex, cmds.txt
#   2. replay cmds.txt through gateware/tb/tb_top.v -> actual.hex
#   3. compare.py                          -> PASS/FAIL (+ diff.ppm)
#
# Output goes to $OUT (default gateware/build/golden). Needs cmake, a C++17
# compiler, iverilog and TinyGPU (TINYGPU_DIR, default ../TinyGPU next to
# this library; TinyMaterialDesign, TINYMD_DIR, is optional). The
# TinyMaterialDesign replay takes several minutes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GW="$HERE/../../gateware"
OUT="${OUT:-$GW/build/golden}"
mkdir -p "$OUT" "$GW/build/sim"

cmake -S "$HERE" -B "$OUT/cmake" -DCMAKE_BUILD_TYPE=Release ${TINYGPU_DIR:+-DTINYGPU_DIR=$TINYGPU_DIR} ${TINYMD_DIR:+-DTINYMD_DIR=$TINYMD_DIR} >/dev/null
cmake --build "$OUT/cmake" >/dev/null
"$OUT/cmake/golden" "$OUT"

cd "$GW"
iverilog -g2012 -DSIMULATION -o build/sim/tb_top tb/tb_top.v tb/sdram_model.v \
  rtl/top_tangnano20k.v rtl/clocks.v rtl/spi_gpu.v rtl/byte_fifo.v rtl/bram_sdp.v \
  rtl/gpu_exec.v rtl/scanout.v rtl/video_timing.v rtl/sdram_ctrl.v rtl/dvi_tx.v \
  rtl/tmds_encoder.v
vvp -n build/sim/tb_top +cmds="$OUT/cmds.txt" +dump="$OUT/actual.hex" | grep -E "PASS|FAIL|replayed"
python3 "$HERE/compare.py" "$OUT/expected.hex" "$OUT/actual.hex" "$OUT/diff.ppm"

# TinyMaterialDesign scene (only if golden found TinyMaterialDesign): the
# replay also checks every READ_DATA readback against the emulator.
if [[ -f "$OUT/cmds_tmd.txt" ]]; then
  vvp -n build/sim/tb_top +sckhalf=2 +readhalf=6 +cmds="$OUT/cmds_tmd.txt" +dump="$OUT/actual_tmd.hex" \
    | grep -E "PASS|FAIL|replayed"
  python3 "$HERE/compare.py" "$OUT/expected_tmd.hex" "$OUT/actual_tmd.hex" "$OUT/diff_tmd.ppm"
fi
