# Building and loading the gateware

A prebuilt bitstream is included at `gateware/build/top_tangnano20k.fs`, so
you only need the toolchain if you change the Verilog.

## Load the prebuilt bitstream

```bash
openFPGALoader -b tangnano20k gateware/build/top_tangnano20k.fs       # SRAM, lost at power-off
openFPGALoader -b tangnano20k -f gateware/build/top_tangnano20k.fs    # flash, persistent
```

or `make load` / `make flash` in `gateware/`.

## Toolchain

| Tool | Version | Notes |
|---|---|---|
| yosys | ≥ 0.33 | `synth_gowin` |
| nextpnr-himbaechel | ≥ 0.11 | Gowin backend |
| Apicula (`gowin_pack`) | **≥ 0.34** | 0.33 crashes when packing the second PLL |
| openFPGALoader | any recent | |
| iverilog | ≥ 11 | simulation |
| cmake, C++17 compiler, Python 3 | | golden-model test |

The [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) ships
all of these. If your system Apicula is older, install a newer `gowin_pack`
into a virtual environment and point the build at it:

```bash
python3 -m venv ~/apycula && ~/apycula/bin/pip install "apycula>=0.34"
make -C gateware bitstream GOWIN_PACK=~/apycula/bin/gowin_pack
```

## Make targets (in `gateware/`)

| Target | What it does |
|---|---|
| `make sim` | unit testbenches plus the full-chip self-test (about 10 s) |
| `make golden` | pixel-exact comparison of three test scenes against their software references (GOLDEN_TIME). Needs TinyGPU next to this library, or `TINYGPU_DIR=...`; the TinyMaterialDesign and H.264 scenes run only if those libraries are found (`TINYMD_DIR`, `TINYH264_DIR`) |
| `make bitstream` | yosys → `fix_bram_oce.py` → nextpnr → gowin_pack (about 8 min) |
| `make load` / `make flash` | program the board |

`make bitstream` prints LUT/BSRAM/PLL use and the post-route Fmax at the
end. Both clocks must stay above 64.8 MHz (`clk`) and 25.2 MHz (`clk_pix`).
