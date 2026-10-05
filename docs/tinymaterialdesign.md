# Using TinyMaterialDesign

[TinyMaterialDesign](https://github.com/pschatzmann/TinyMaterialDesign) is a
Material Design 3 widget library built on TinyGPU. It works with
TangNanoGPU: the widget tree draws straight onto `SurfaceTangNano`, so the
Tang Nano 20K renders every widget into its own framebuffer and the
microcontroller needs **no framebuffer at all**. On an ESP32 without PSRAM,
a full-screen framebuffer is often the hardest part.

See `examples/material-design` for a complete sketch.

## Installation

Put TinyMaterialDesign next to TinyGPU and TangNanoGPU in your Arduino
`libraries` folder (see [installation.md](installation.md)):

```bash
cd ~/Documents/Arduino/libraries
git clone https://github.com/pschatzmann/TinyMaterialDesign.git
```

## Use `Screen`, not `App`

TinyMaterialDesign's `App` class is a convenience for LCD boards. It needs a
TinyGPU `LCDBoard` with a touch panel, and it keeps a full-screen
`Surface<RGB565>` on the MCU. With TangNanoGPU, use `Screen` directly
instead:

```cpp
#include <SPI.h>
#include <TangNanoGPU.h>
#include <TinyMaterialDesign.h>

TransportSPI transport(SPI, /*cs=*/5, /*busy=*/4);
TangNanoGPU gpu(transport);
SurfaceTangNano surface(gpu);

Screen<RGB565> screen(defaultTheme<RGB565>());
Button<RGB565> button(Bounds(16, 184, 150, 40), "Hello");

void setup() {
  gpu.begin();
  surface.begin();
  surface.setTarget(1);              // draw into the hidden buffer
  screen.addWidget(button);
}

void loop() {
  screen.update(millis());           // animations (ripples, spinners, ...)
  if (screen.isDirty()) {
    screen.draw(surface);            // rendered by the FPGA
    surface.swap();                  // shown at the next frame, tear-free
    gpu.flush();                     // stay at most one frame ahead
  }
}
```

The screen is 320×240, so lay out widgets for that size. Widgets that take
their width from the screen, such as `app.width()` in TinyMaterialDesign's
examples, should use `kWidth` / `kHeight` or literal values.

`Screen::draw()` always repaints the whole screen. With `surface.swap()` the
repaint goes into the hidden buffer, so it never flickers. Without double
buffering you would see the clear-and-redraw happen.

## Input

The HDMI output has no touch panel, so gestures must come from somewhere
else. TinyMaterialDesign gets its input from a TinyGPU `GestureDetector`,
which reads any TinyGPU `TouchDriver`:

```cpp
GestureDetector gestures;

void setup() {
  // ...
  gestures.onGesture = [](GestureEvent& e) { screen.handleGesture(e); };
  gestures.isDraggable = [](int16_t x, int16_t y) { return screen.isDraggableAt(x, y); };
}

void loop() {
  gestures.update(touch);            // any tinygpu::TouchDriver
  // ... update/draw as above
}
```

The `touch` object can be any of these:

- **Serial commands:** `examples/material-design` includes `SerialTouch`,
  which turns `tap x y` and `drag x0 y0 x1 y1` lines from the Serial
  Monitor into touches. It is handy for trying things out.
- **A touch panel:** a resistive or capacitive panel wired to the MCU, using
  TinyGPU's `TouchDriverArduino` drivers (XPT2046, FT6236, CST816S, GT911).
  Scale the panel's coordinates to 320×240.
- **Your own driver:** derive from `tinygpu::TouchDriver` and implement
  `begin()`, `isTouched()` and `getPoint()`. Buttons, a rotary encoder that
  moves a cursor, a joystick and so on all work this way.

## Performance

| Situation | SPI traffic per redraw | Time at 10 MHz |
|---|---|---|
| Typical screen (app bar, labels, switch, checkbox, slider, progress bars, button) | about 20 KB of commands | about 20–40 ms (25–50 redraws/s) |
| Same screen with a `Dialog` presented | plus about 154 KB read back and 157 KB written | about 0.5 s |

Most of a normal frame is TinyGPU's `fillRoundRect`. Its default
implementation issues one `fillRect` per row, so each rounded widget costs a
few dozen small FILL_RECT commands. The drawing on the FPGA is never the
bottleneck.

### Modal dialogs, drawers and menus

The dimmed background ("scrim") behind a `Dialog`, `Drawer`, `Menu` or
`BottomSheet` comes from TinyMaterialDesign's `drawScrim()`. It reads every
pixel with `getPixel()`, darkens it, and writes it back with `setPixel()`.
On an in-memory surface that is cheap. Here, every pixel lives in the FPGA,
so `SurfaceTangNano` takes two steps to make it workable:

- `getPixel()` reads a **whole framebuffer row** over SPI once and serves
  the other 319 pixels of that row from a cache. The cache is invalidated
  by the next drawing command.
- Consecutive `setPixel()` calls along a row are sent as **one WRITE_RECT**
  (2 bytes per pixel) instead of individual 6-byte pixel records.

That makes a scrim cost one readback per row, 240 in total, which is about
half a second per redraw while a modal is open. Dialogs therefore work
correctly but react slowly. Keep redraws rare while a modal is shown: avoid
indeterminate progress indicators and other animations behind it.

## Semantics

`SurfaceTangNano` follows TinyGPU's surface rules exactly:

- `setPixel()` ignores the clip rect, like TinyGPU's in-memory surfaces. The
  FPGA's PIXELS command and the `setPixel` runs are bounded only by the
  screen.
- `fillRect`, lines, circles, sprites and text honour the clip rect that
  `Container` scrolling and `pushClipRect()` set.
- Text from any TinyGPU font is drawn as one MASK command per `drawText()`.

## Verification

`make golden` (in `gateware/`) renders a TinyMaterialDesign screen with a
presented dialog in three ways:

1. TinyMaterialDesign drawing into a software `Surface<RGB565>`: the
   reference.
2. `SurfaceTangNano` over a protocol emulator. This exercises the row cache,
   the `setPixel` runs and the text masks, and must match the reference.
3. The recorded command stream replayed into the RTL. Each of the 240
   readbacks must return the same bytes as the emulator, and the final
   framebuffer must match the reference.

All three are pixel-identical. The check is skipped if TinyMaterialDesign
isn't found next to this library (`TINYMD_DIR`).
