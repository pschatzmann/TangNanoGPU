# Building and loading the gateware

Two prebuilt bitstreams are included, so you only need the toolchain if
you change the Verilog:

| File | Picture output |
|---|---|
| `gateware/build/top_tangnano20k.fs` | HDMI (640×480) |
| `gateware/build/lcd/top_tangnano20k.fs` | 4.3" 480×272 RGB panel on the 40-pin connector |

## Load the prebuilt bitstream

```bash
openFPGALoader -b tangnano20k gateware/build/top_tangnano20k.fs       # SRAM, lost at power-off
openFPGALoader -b tangnano20k -f gateware/build/top_tangnano20k.fs    # flash, persistent
```

or `make load` / `make flash` in `gateware/` (add `VIDEO=lcd` for the LCD
bitstream).

## Toolchain

| Tool | Version | Notes |
|---|---|---|
| yosys | ≥ 0.33 | `synth_gowin` |
| nextpnr-himbaechel | ≥ 0.11 | Gowin backend |
| Apicula (`gowin_pack`) | **≥ 0.34** | 0.33 crashes when packing the second PLL |
| openFPGALoader | any recent | |
| iverilog | ≥ 11 | simulation |
| cmake, C++17 compiler, Python 3 | | golden-model test |
| arduino-cli + ESP32/RP2040 cores | | `make examples` (optional) |

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
| `make sim` | unit testbenches, the video output checked pixel by pixel for HDMI and LCD, and the full-chip self-test over SPI (10.8 and ~42 MHz), quad SPI (~42 MHz), with the real 200 µs SDRAM start-up, and as an LCD build; about 4 min |
| `make golden` | pixel-exact comparison of three test scenes against their software references, replayed over quad SPI (about 1 min for the TinyGPU scene; about 45 min with both optional scenes, mostly the TinyMaterialDesign readbacks). Needs TinyGPU next to this library, or `TINYGPU_DIR=...`; the TinyMaterialDesign and H.264 scenes run only if those libraries are found (`TINYMD_DIR`, `TINYH264_DIR`) |
| `make examples` | compiles every example with arduino-cli for ESP32, ESP32-S3 and RP2040, plus the quad variants (`tools/compile_examples.sh`; skipped without arduino-cli) |
| `make bitstream` | yosys → `fix_bram_oce.py` → nextpnr → gowin_pack (about 10–25 min, mostly place & route) |
| `make load` / `make flash` | program the board |

`make bitstream` prints LUT/BSRAM/PLL use and the post-route Fmax at the
end. Both clocks must stay above 64.8 MHz (`clk`) and 25.2 MHz (`clk_pix`).
The `u_spi.sck` figure only covers register-to-register paths inside the
FPGA; see [architecture.md](architecture.md#resources-gw2ar-18c-yosys-033--nextpnr-himbaechel-011)
for what limits the SPI clock in practice.

### Build options

| Option | Values | Effect |
|---|---|---|
| `VIDEO=` | `hdmi` (default), `lcd` | picture on HDMI, or on a 480×272 RGB panel on the 40-pin connector (no HDMI; MCU link moves to pins 73–76/71, see [pinout.md](pinout.md)) |
| `LINK=` | `qspi` (default), `spi` | single-line and quad SPI, or single-line only (frees the IO2/IO3 pins) |

| Build | Output |
|---|---|
| `make bitstream` | `build/top_tangnano20k.fs` (prebuilt) |
| `make bitstream LINK=spi` | `build/spi/top_tangnano20k.fs` |
| `make bitstream VIDEO=lcd` | `build/lcd/top_tangnano20k.fs` (prebuilt) |
| `make bitstream VIDEO=lcd LINK=spi` | `build/lcd/spi/top_tangnano20k.fs` |

All variants answer PING with their capabilities, so the library can tell
a quad-capable bitstream from a single-line one. The host library and the
320×240 framebuffer are the same for HDMI and LCD.
