# TangNanoGPU

[![Arduino Library](https://img.shields.io/badge/Arduino-Library-blue.svg)](https://www.arduino.cc/reference/en/libraries/)
[![License: Apache](https://img.shields.io/badge/License-Apache-yellow.svg)](https://opensource.org/licenses/Apache-2.0)

TangNanoGPU makes a [**Sipeed Tang Nano 20K**](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html) FPGA board into an HDMI
graphics card for
[TinyGPU](https://github.com/pschatzmann/TinyGPU).

<img src="https://wiki.sipeed.com/hardware/zh/tang/tang-nano-20k/assets/nano_20k/tang_nano_20k_3920_top.png" alt="Sipeed Tang Nano 20K" width="300">


Your microcontroller (ESP32, RP2040, STM32, …) keeps calling TinyGPU's
drawing API. The calls go over SPI (or quad SPI) as short commands. The FPGA draws them
into a framebuffer in its SDRAM and sends the picture to HDMI in the
background, so the MCU needs no framebuffer of its own and does no pixel
pushing.

```
 ESP32 / RP2040 ──SPI / QSPI──▶ Tang Nano 20K ──HDMI──▶ monitor
 TinyGPU calls                  draws in hardware,       640×480@60
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
- **Video:** decoded video, for example H.264 from
  [TinyH264](https://github.com/pschatzmann/TinyH264), is sent as YUV 4:2:0
  macroblocks (1.5 bytes per pixel). The FPGA converts them to RGB565, and
  `YUVFrameWriter` sends only the macroblocks that changed. See
  [docs/video.md](docs/video.md).
- **Material Design 3 GUIs:**
  [TinyMaterialDesign](https://github.com/pschatzmann/TinyMaterialDesign)
  screens draw straight onto `SurfaceTangNano`, including dialogs, drawers
  and menus. The MCU needs no framebuffer for this. See
  [docs/tinymaterialdesign.md](docs/tinymaterialdesign.md).
- **Fast host link, selectable:** plain SPI (any MCU, ~32 MHz) or quad SPI
  for write transactions (ESP32 family, ~40 MHz × 4 lines). One bitstream
  accepts both; the sketch picks `TransportSPI` or `TransportQSPI_ESP32`.
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
2. **Wire the MCU** (3.3 V): SCK → pin 27, MOSI → 28, MISO ← 29,
   CS → 30, BUSY ← 31, and GND (the same SPI pins as TangNanoFaust and
   TangNanoAI). For quad SPI on an ESP32 also IO2 → 25 and IO3 → 26. See
   [docs/pinout.md](docs/pinout.md).
3. **Install the libraries:** put this library and
   [TinyGPU](https://github.com/pschatzmann/TinyGPU) in your Arduino
   `libraries` folder. Add
   [TinyMaterialDesign](https://github.com/pschatzmann/TinyMaterialDesign)
   for widget GUIs,
   [TinyH264](https://github.com/pschatzmann/TinyH264) for `video-player`,
   or lvgl for `lvgl-example`.
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

### Video

```cpp
YUVFrameWriter video(gpu);

// in the TinyH264 frame callback:
if (video.macroblocks() == 0) video.begin(d.width(), d.height());  // centred
video.writeFrame(d.y(), d.strideY(), d.u(), d.v(), d.strideUV());   // changed macroblocks only
screen.swap();
```

## Examples

| Example | Shows |
|---|---|
| `ping` | link check, STATUS, frame counter |
| `basic-example` | TinyGPU primitives and text on HDMI |
| `bouncing-ball` | double-buffered animation |
| `sprite-blit` | 40 sprites blitted from SDRAM per frame |
| `wireframe-cube` | TinyGPU `WireFrame3D` |
| `lvgl-example` | LVGL v9 through `LVGLDriver` + `DisplayDriverTangNano` |
| `video-player` | H.264 clip decoded by TinyH264 on the MCU; changed YUV macroblocks shown via the FPGA ([docs](docs/video.md)) |
| `link-benchmark` | measures the link (full frame, small commands, readback); compare SPI and quad SPI |
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

Streaming raw pixels is limited by the link: a full 320×240 RGB565 frame
(153.6 KB) needs about 38 ms of bus time over SPI at 32 MHz and about 8 ms
over quad SPI at 40 MHz, so upload reused images once and blit them. A
typical TinyMaterialDesign screen redraw is about 20 KB of commands. While
a modal dialog is open, its full-screen scrim needs a readback at the 4 MHz
read clock, about 0.4 s per redraw.

For video, a 16×16 macroblock is 388 bytes: about 0.1 ms over SPI at
32 MHz, 0.04 ms over quad SPI. In the test clip about 12% of macroblocks
change per frame: roughly 14 KB, or 3.4 ms (SPI) / 0.7 ms (quad) per
frame. The FPGA converts a macroblock in about 18 µs (estimated
from the state machine), so decoding on the MCU is usually what limits the
frame rate.

## Documentation

- [docs/installation.md](docs/installation.md): Arduino setup, wiring,
  loading the bitstream, and the FPGA toolchain
- [docs/tinymaterialdesign.md](docs/tinymaterialdesign.md): Material Design 3
  widgets on HDMI, input options, performance
- [docs/video.md](docs/video.md): video playback, YUV macroblocks, change
  detection, performance
- [docs/architecture.md](docs/architecture.md): design, clocks, SDRAM
  bursts, scanout, resources, verification status
- [docs/protocol.md](docs/protocol.md): the link layer (SPI / quad SPI) and
  the command set
- [docs/pinout.md](docs/pinout.md): wiring and on-board pins
- [docs/building.md](docs/building.md): make targets for simulation and
  building the bitstream (rebuilding needs Apicula ≥ 0.34)

## Testing

All checks run from `gateware/`:

| Command | What it confirms |
|---|---|
| `make test` | everything below except the bitstream |
| `make sim` | unit testbenches and the full-chip self-test over SPI and quad SPI (~20 s) |
| `make golden` | the three pixel-exact golden-model scenes (TinyGPU, TinyMaterialDesign, H.264 video; ~1–45 min depending on installed libraries) |
| `make examples` | every example compiles for ESP32, ESP32-S3 and RP2040, including the quad variants |
| `make bitstream` | the design builds and meets timing |

Details: [docs/installation.md](docs/installation.md#build-and-test).

## Status

| Area | Status |
|---|---|
| RTL simulation | Passes: unit testbenches, a full-chip test over the real pins (SPI at 10.8 and ~42 MHz, quad SPI at ~42 MHz), and the pixel-exact golden-model tests (TinyGPU scene, TinyMaterialDesign, H.264 video) |
| TinyMaterialDesign | A screen with an open dialog renders pixel-identically, both through a protocol emulator and replayed into the RTL (240 readbacks checked) |
| Toolchain | Synthesises, routes, meets timing (93 MHz / 89 MHz against 64.8 / 25.2 MHz) and packs; 40% of the LUTs, 7 of 46 block RAMs |
| Video | TinyH264-decoded frames match TinyH264's own RGB565 output pixel for pixel through `YUVFrameWriter`: all 30 frames via the protocol emulator, the first 8 replayed into the RTL. The converter matches for all 16.7 M YUV inputs |
| Arduino library | All examples compile for ESP32; `ping`, `basic-example`, `sprite-blit`, `material-design` and `video-player` also for RP2040 |
| Real hardware | **In progress.** On a real Tang Nano 20K the clocks, HDMI timing generator and SDRAM initialisation run, and no error flags are set. HDMI picture, SPI link and drawing are not tested yet; see [docs/architecture.md](docs/architecture.md#verification-status) |

## License

Apache-2.0. The SDRAM init and read timing follow nand2mario's Apache-2.0
controller (via [TangNanoAI](https://github.com/pschatzmann/TangNanoAI)).
The HDMI output structure follows Apicula's DVI example. The test clips are
generated from ffmpeg's built-in test sources (`tools/golden/clips`). This
library does not depend on TinyH264, which is GPL-3.0; sketches that link
it, such as `video-player`, fall under that license.
