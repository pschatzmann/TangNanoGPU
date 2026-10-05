# TangNanoGPU

[![Arduino Library](https://img.shields.io/badge/Arduino-Library-blue.svg)](https://www.arduino.cc/reference/en/libraries/)
[![License: Apache](https://img.shields.io/badge/License-Apache-yellow.svg)](https://opensource.org/licenses/Apache-2.0)

TangNanoGPU makes a **Sipeed Tang Nano 20K** FPGA board into an HDMI
graphics card for
[TinyGPU](https://github.com/pschatzmann/TinyGPU).

<img src="https://wiki.sipeed.com/hardware/zh/tang/tang-nano-20k/assets/nano_20k/tang_nano_20k_3920_top.png" alt="Sipeed Tang Nano 20K" width="300">


Your microcontroller (ESP32, RP2040, STM32, …) keeps calling TinyGPU's
drawing API. The calls go over SPI as short commands. The FPGA draws them
into a framebuffer in its SDRAM and sends the picture to HDMI in the
background, so the MCU needs no framebuffer of its own and does no pixel
pushing.

```
 ESP32 / RP2040 ──SPI──▶ Tang Nano 20K ──HDMI──▶ monitor
 TinyGPU calls           draws in hardware,       640×480@60
                         8 MB SDRAM framebuffer
```

## Features

- **Display:** 320×240 RGB565 framebuffer shown as 640×480@60 HDMI/DVI,
  each pixel doubled. There are two framebuffers, so animation is
  double-buffered and tear-free.
- **Drawing in hardware:** fills, lines, circles (outline and filled),
  single pixels, sprite and bitmap writes with colour-key transparency,
  text, clipping, scrolling, and readback.
- **SDRAM image store:** upload sprites once (`uploadImage()`) and draw them
  with tiny `blit()` commands.
- **Pixel-identical to TinyGPU:** the FPGA uses TinyGPU's own line, circle
  and clipping algorithms. A golden-model test compares the RTL output
  against TinyGPU's software renderer pixel by pixel.
- **Drop-in for TinyGPU:**
  - `SurfaceTangNano` is a TinyGPU `ISurface<RGB565>`. Primitives, any
    `IFont`, `WireFrame3D`, `CartesianView` and TinyMaterialDesign widgets
    draw on it directly.
  - `DisplayDriverTangNano` is a TinyGPU `DisplayDriver<RGB565>`. Use it
    with `DeviceOutput` or with `LVGLDriver` for LVGL.
- **Material Design 3 GUIs:**
  [TinyMaterialDesign](https://github.com/pschatzmann/TinyMaterialDesign)
  screens draw straight onto `SurfaceTangNano`, including dialogs, drawers
  and menus. The MCU needs no framebuffer for this. See
  [docs/tinymaterialdesign.md](docs/tinymaterialdesign.md).
- **Open-source gateware:** Verilog built with yosys, nextpnr-himbaechel and
  Apicula. A prebuilt bitstream is included.

## Getting started

Step-by-step instructions, including installing openFPGALoader and
troubleshooting, are in [docs/installation.md](docs/installation.md).

1. **Load the bitstream:**

   ```bash
   openFPGALoader -b tangnano20k -f gateware/build/top_tangnano20k.fs
   ```

   Connect a monitor and hold button **S2**: you should see colour bars.
2. **Wire the MCU** (3.3 V): SCK → pin 73, MOSI → 74, MISO ← 75,
   CS → 76, BUSY ← 71, and GND. See [docs/pinout.md](docs/pinout.md).
3. **Install the libraries:** put this library and
   [TinyGPU](https://github.com/pschatzmann/TinyGPU) in your Arduino
   `libraries` folder. Add
   [TinyMaterialDesign](https://github.com/pschatzmann/TinyMaterialDesign)
   for widget GUIs, or lvgl for `lvgl-example`.
4. **Check the link:** run `examples/ping`, then `examples/basic-example`.

```cpp
#include <SPI.h>
#include <TangNanoGPU.h>

TransportSPI transport(SPI, /*cs=*/5, /*busy=*/4);
TangNanoGPU gpu(transport);
SurfaceTangNano screen(gpu);           // a TinyGPU ISurface<RGB565>

void setup() {
  gpu.begin();
  screen.begin();
  screen.clear(RGB565(0, 0, 64));
  screen.fillCircle(160, 120, 50, RGB565(255, 200, 0));
  screen.drawText(10, 10, "Hello HDMI", RGB565(255, 255, 255));
}
void loop() {}
```

### Double buffering

```cpp
screen.setTarget(1);                   // draw into the hidden buffer
// ... draw a frame ...
screen.swap();                         // show it at the next vblank, continue in the other buffer
gpu.flush();                           // optional: stay at most one frame ahead
```

### Sprites in SDRAM

```cpp
gpu.uploadImage(kImageRowBase, 24, 24, sprite.data());   // once
gpu.blit(kImageRowBase, 24, 24, x, y, /*useKey=*/true, /*key=*/0);  // every frame
```

### Material Design widgets

```cpp
Screen<RGB565> ui(defaultTheme<RGB565>());   // TinyMaterialDesign
Button<RGB565> button(Bounds(16, 184, 150, 40), "Hello");

// setup(): ui.addWidget(button); screen.setTarget(1);
// loop():
ui.update(millis());
if (ui.isDirty()) {
  ui.draw(screen);                     // rendered by the FPGA
  screen.swap();
  gpu.flush();
}
```

Touch input comes from any TinyGPU `TouchDriver`. The `material-design`
example includes one driven by Serial commands.

## Examples

| Example | Shows |
|---|---|
| `ping` | link check, STATUS, frame counter |
| `basic-example` | TinyGPU primitives and text on HDMI |
| `bouncing-ball` | double-buffered animation |
| `sprite-blit` | 40 sprites blitted from SDRAM per frame |
| `wireframe-cube` | TinyGPU `WireFrame3D` |
| `lvgl-example` | LVGL v9 through `LVGLDriver` + `DisplayDriverTangNano` |
| `material-design` | [TinyMaterialDesign](https://github.com/pschatzmann/TinyMaterialDesign) widgets rendered by the FPGA, with no MCU framebuffer ([docs](docs/tinymaterialdesign.md)) |

## Performance

Measured in simulation at 64.8 MHz:

| Operation | Time |
|---|---|
| full-screen clear | 0.72 ms |
| 320-pixel line | 87 µs |
| filled circle, r = 100 | 385 µs |
| full-screen scroll | 2.6 ms |
| 24×24 sprite blit | 39 µs |

Streaming raw pixels is limited by SPI. A full 320×240 frame takes about
125 ms at 10 MHz, so upload reused images once and blit them. A typical
TinyMaterialDesign screen redraw is about 20 KB of commands (20–40 ms).
While a modal dialog is open, its full-screen scrim needs a readback, which
takes about 0.5 s per redraw.

## Documentation

- [docs/installation.md](docs/installation.md): Arduino setup, wiring,
  loading the bitstream, and the FPGA toolchain
- [docs/tinymaterialdesign.md](docs/tinymaterialdesign.md): Material Design 3
  widgets on HDMI, input options, performance
- [docs/architecture.md](docs/architecture.md): design, clocks, SDRAM
  bursts, scanout, resources, verification status
- [docs/protocol.md](docs/protocol.md): the SPI command set
- [docs/pinout.md](docs/pinout.md): wiring and on-board pins
- [docs/building.md](docs/building.md): make targets for simulation and
  building the bitstream (rebuilding needs Apicula ≥ 0.34)

## Status

| Area | Status |
|---|---|
| RTL simulation | Passes: unit testbenches, a full-chip test over the real SPI pins, and the pixel-exact golden-model test |
| TinyMaterialDesign | A screen with an open dialog renders pixel-identically, both through a protocol emulator and replayed into the RTL (240 readbacks checked) |
| Toolchain | Synthesises, routes, meets timing (89 MHz / 82 MHz against 64.8 / 25.2 MHz) and packs |
| Arduino library | All examples compile for ESP32; `ping`, `basic-example`, `sprite-blit` and `material-design` also for RP2040 |
| Real hardware | **Not tested yet.** No board was attached during development; see the bring-up order in [docs/architecture.md](docs/architecture.md#verification-status) |

## License

Apache-2.0. The SDRAM init and read timing follow nand2mario's Apache-2.0
controller (via [TangNanoAI](https://github.com/pschatzmann/TangNanoAI)).
The HDMI output structure follows Apicula's DVI example.
