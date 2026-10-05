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
| `make test` | `sim` + `golden` + `examples`: everything that confirms a change, except the bitstream |
| `make sim` | unit testbenches plus the full-chip self-test over SPI (10.8 and ~42 MHz) and quad SPI (~42 MHz), about 20 s |
| `make golden` | pixel-exact comparison of three test scenes against their software references, replayed over quad SPI (about 1 min for the TinyGPU scene; about 45 min with both optional scenes, mostly the TinyMaterialDesign readbacks). Needs TinyGPU next to this library, or `TINYGPU_DIR=...`; the TinyMaterialDesign and H.264 scenes run only if those libraries are found (`TINYMD_DIR`, `TINYH264_DIR`) |
| `make examples` | compiles every example with arduino-cli for ESP32, ESP32-S3 and RP2040, plus the quad variants (`tools/compile_examples.sh`; skipped without arduino-cli) |
| `make bitstream` | yosys → `fix_bram_oce.py` → nextpnr → gowin_pack (about 10–25 min, mostly place & route) |
| `make load` / `make flash` | program the board |

`make bitstream` prints LUT/BSRAM/PLL use and the post-route Fmax at the
end. Both clocks must stay above 64.8 MHz (`clk`) and 25.2 MHz (`clk_pix`).

### Interface option

| `LINK=` | Output | Host interfaces |
|---|---|---|
| `qspi` (default, prebuilt) | `build/top_tangnano20k.fs` | single-line SPI and quad SPI (IO2/IO3 on pins 25/26) |
| `spi` | `build/spi/top_tangnano20k.fs` | single-line SPI only; pins 25/26 stay free |

Both kinds answer PING with their capabilities, so the library can tell
them apart.
