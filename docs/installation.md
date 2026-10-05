# Installation

There are two parts:

1. **[Arduino](#part-1-arduino)**: set up the microcontroller, load the prebuilt bitstream and run the examples. This is all you need to use the board.
2. **[FPGA toolchain](#part-2-fpga-toolchain)**: only needed to simulate or rebuild the gateware after changing the Verilog.

## Part 1: Arduino

This part sets up a microcontroller (ESP32, RP2040, STM32, …) to drive a Tang Nano 20K running the TangNanoGPU bitstream. You do **not** need any FPGA tools for this: a prebuilt bitstream is included. To change the Verilog, see [Part 2](#part-2-fpga-toolchain).

### What you need

- A Sipeed **Tang Nano 20K** and a USB-C cable
- A 3.3 V microcontroller with hardware SPI (the examples cover ESP32 and RP2040)
- An HDMI monitor or TV that accepts 640×480@60 (almost all do)
- 6 jumper wires

### 1. Install the Arduino libraries

TangNanoGPU depends on [TinyGPU](https://github.com/pschatzmann/TinyGPU). Install both into your Arduino `libraries` folder:

```bash
cd ~/Documents/Arduino/libraries      # Linux: often ~/Arduino/libraries
git clone https://github.com/pschatzmann/TinyGPU.git
git clone https://github.com/pschatzmann/TangNanoGPU.git
```

Alternatively, download each repository as a ZIP and use **Sketch → Include Library → Add .ZIP Library…** in the Arduino IDE.

Optional libraries, only needed for some examples:

| Library | Example | Notes |
|---|---|---|
| [TinyMaterialDesign](https://github.com/pschatzmann/TinyMaterialDesign) | `material-design` | see [tinymaterialdesign.md](tinymaterialdesign.md) |
| [TinyH264](https://github.com/pschatzmann/TinyH264) | `video-player` | GPL-3.0; see [video.md](video.md) |
| lvgl (v9, Library Manager) | `lvgl-example` | needs an `lv_conf.h` with `#define LV_COLOR_DEPTH 16` |

Install them the same way (`git clone` into `libraries`).

### 2. Install a board core

Use the normal Arduino board support for your MCU, for example:

| MCU | Board core (Boards Manager) |
|---|---|
| ESP32 | `esp32` by Espressif |
| RP2040 / RP2350 | `Raspberry Pi Pico/RP2040/RP2350` by Earle Philhower |

### 3. Load the bitstream onto the Tang Nano 20K

The bitstream is in the library at `gateware/build/top_tangnano20k.fs`. Program it with [openFPGALoader](https://github.com/trabucayre/openFPGALoader), which is available as a package on most systems (`sudo apt install openfpgaloader`, `brew install openfpgaloader`, or the Windows release):

```bash
cd ~/Documents/Arduino/libraries/TangNanoGPU
openFPGALoader -b tangnano20k -f gateware/build/top_tangnano20k.fs   # flash: survives power-off
```

Use `openFPGALoader -b tangnano20k gateware/build/top_tangnano20k.fs` (without `-f`) to load it into SRAM only, for a quick test.

On Linux, if openFPGALoader reports `unable to open ftdi device`, install its udev rules (see the openFPGALoader documentation) or run it once with `sudo`.

**Check:** connect the monitor and hold button **S2**. You should see eight colour bars. LED 0 blinks as a heartbeat; LED 1 lights once the SDRAM is ready.

### 4. Wire the microcontroller

All signals are 3.3 V. Connect GND first.

| Tang Nano 20K pin | Signal | ESP32 | RP2040 (Pico) |
|---|---|---|---|
| 73 | SCK | GPIO 18 | GP18 |
| 74 | MOSI | GPIO 23 | GP19 |
| 75 | MISO | GPIO 19 | GP16 |
| 76 | CS | GPIO 5 | GP17 |
| 71 | BUSY | GPIO 4 | GP20 |
| GND | GND | GND | GND |

BUSY is optional but strongly recommended: without it, the library has to poll the board before sending larger images, which is slower. Other pins are fine; change `kCsPin`/`kBusyPin` in the sketch (and the SPI pins of your core) to match. Full details: [pinout.md](pinout.md).

### 5. Run the examples

1. **File → Examples → TangNanoGPU → ping.** Open the Serial Monitor at 115200 baud. It prints the gateware version and a status line every half second while the screen cycles through colours.
2. **basic-example**: TinyGPU shapes and text on HDMI.
3. Then `bouncing-ball`, `sprite-blit` and `wireframe-cube`, and, with the optional libraries, `material-design`, `video-player` and `lvgl-example`.

A minimal sketch:

```cpp
#include <SPI.h>
#include <TangNanoGPU.h>

TransportSPI transport(SPI, /*cs=*/5, /*busy=*/4);
TangNanoGPU gpu(transport);
SurfaceTangNano screen(gpu);

void setup() {
  gpu.begin();
  screen.begin();
  screen.clear(RGB565(0, 0, 64));
  screen.drawText(10, 10, "Hello HDMI", RGB565(255, 255, 255));
}
void loop() {}
```

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| No picture, even with S2 held | Bitstream not loaded, or the monitor is on the wrong input. Re-run openFPGALoader and check that LED 0 blinks. |
| Colour bars work, `ping` says "No answer" | Wiring (MISO/SCK swapped, missing GND), wrong CS pin, or the bitstream was loaded into SRAM and the board was power-cycled since. |
| `ping` works, drawings are corrupted or incomplete | Lower the SPI write clock: `TransportSPI transport(SPI, cs, busy, 4000000);`. Make sure BUSY is wired. |
| Status shows `ERROR` | A command was lost (FIFO overflow without BUSY) or the stream got out of sync. `gpu.reset()` recovers; then wire BUSY or reduce the clock. |
| Compile error `'TwoWire' does not name a type` | Include `<TangNanoGPU.h>` rather than `<TinyGPU.h>` first; it pulls in `Wire.h` for TinyGPU. |

## Part 2: FPGA toolchain

This part sets up the open-source FPGA toolchain to simulate and rebuild the TangNanoGPU gateware. You only need it if you change the Verilog; to just use the board, the prebuilt bitstream is enough (see [Part 1](#part-1-arduino)).

### Tools

| Tool | Minimum version | Used for |
|---|---|---|
| [yosys](https://github.com/YosysHQ/yosys) | 0.33 | synthesis (`synth_gowin`) |
| [nextpnr-himbaechel](https://github.com/YosysHQ/nextpnr) | 0.11, with the Gowin backend | place & route |
| [Apicula](https://github.com/YosysHQ/apicula) (`gowin_pack`) | **0.34** | bitstream packing |
| [openFPGALoader](https://github.com/trabucayre/openFPGALoader) | any recent | programming the board |
| [Icarus Verilog](https://github.com/steveicarus/iverilog) | 11 | simulation (`make sim`) |
| cmake, a C++17 compiler, Python 3 | | golden-model test (`make golden`) |
| GNU make | | build |

**Apicula 0.34 or newer is required.** The design uses both of the chip's PLLs, and `gowin_pack` 0.33 crashes on the second one with `UnboundLocalError: cannot access local variable 'offx'`.

### Option A: OSS CAD Suite (recommended)

The [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) bundles yosys, nextpnr-himbaechel, Apicula, openFPGALoader and iverilog in matching, current versions.

```bash
# download the archive for your OS from the releases page, then:
tar xzf oss-cad-suite-linux-x64-<date>.tgz
source oss-cad-suite/environment.sh     # once per shell
```

### Option B: distribution packages + pip

```bash
# Debian / Ubuntu
sudo apt install yosys iverilog openfpgaloader cmake g++ make python3-venv
```

Distributions often ship no `nextpnr-himbaechel`, or one without the Gowin backend; in that case take it from the OSS CAD Suite or build it from source with `-DARCH=himbaechel -DHIMBAECHEL_UARCH=gowin`.

Install Apicula with pip. If another project already depends on an older system-wide Apicula, put the new one in its own virtual environment instead of upgrading:

```bash
python3 -m venv ~/apycula
~/apycula/bin/pip install "apycula>=0.34"
```

and pass it to the build: `make bitstream GOWIN_PACK=~/apycula/bin/gowin_pack`.

### Check the installation

```bash
yosys -V
nextpnr-himbaechel --version
gowin_pack --help | head -1          # or ~/apycula/bin/gowin_pack
python3 -c "import importlib.metadata as m; print(m.version('apycula'))"   # must be >= 0.34
iverilog -V | head -1
openFPGALoader --detect              # with the board plugged in
```

### Build and test

All commands run in `gateware/`:

| Command | What it does | Time |
|---|---|---|
| `make sim` | unit testbenches + full-chip self-test | ~10 s |
| `make golden` | renders test scenes in software and in the RTL and compares all 76,800 pixels of each (see [architecture.md](architecture.md#exactness-against-tinygpu)). Needs TinyGPU next to this library, or `TINYGPU_DIR=/path/to/TinyGPU`. The TinyMaterialDesign and video scenes run only if those libraries are found (`TINYMD_DIR`, `TINYH264_DIR`) | GOLDEN_TIME |
| `make bitstream` | yosys → `tools/fix_bram_oce.py` → nextpnr → gowin_pack, writes `build/top_tangnano20k.fs` | ~8 min |
| `make load` | loads the bitstream into SRAM (lost at power-off) | |
| `make flash` | writes it to the onboard flash | |

`make bitstream` ends by printing LUT/BSRAM/PLL use and Fmax. The second (post-route) Fmax figures must stay above **64.8 MHz** for `clk` and **25.2 MHz** for `clk_pix`.

Run `make sim` and `make golden` after every RTL change; both must print `PASS`.

### Known toolchain issues

| Message | Cause and fix |
|---|---|
| `UnboundLocalError: cannot access local variable 'offx'` in `gowin_pack` | Apicula 0.33. Use ≥ 0.34 (see above). |
| `no BELs remaining to implement cell type 'SDPX9'` (or `DPX9`) | yosys 0.33 maps inferred dual-port RAMs to cells nextpnr 0.11 cannot place. The design avoids this by instantiating `SDPB` in `rtl/bram_sdp.v`; use that wrapper for any new dual-port memory. |
| Block RAM reads return garbage on hardware | yosys 0.33 ties the BSRAM output enable low. The Makefile runs `tools/fix_bram_oce.py` on the netlist; keep it in custom flows. |
| `ERROR: Unconstrained IO: ...` | A top-level port has no `IO_LOC` in `constraints/tangnano20k.cst`, or an `O_sdram_*`/`IO_sdram_dq` port was renamed (those are placed by name). |
| `Command syntax error: Unknown option` at `synth_gowin ... -family gw2a` | yosys 0.33's `synth_gowin` has no `-family` option (newer versions do); the Makefile doesn't use it. |
