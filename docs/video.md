# Video playback

TangNanoGPU can show decoded video, for example H.264 decoded by
[TinyH264](https://github.com/pschatzmann/TinyH264) on the
microcontroller. Responsibilities are split like this:

| Where | What |
|---|---|
| MCU | decodes the bitstream into YUV 4:2:0 (I420) planes |
| MCU, `YUVFrameWriter` | finds the 16×16 macroblocks that changed and sends only those |
| SPI | 1.5 bytes per pixel (YUV) instead of 2 (RGB565) |
| FPGA, `YUV_MBS` command | converts YUV to RGB565 (BT.601) and writes the macroblock into the framebuffer |
| FPGA scanout | shows the frame on HDMI; double buffering switches frames tear-free |

The FPGA does not decode H.264 itself. A hardware decoder would not fit
next to the drawing engine on the GW2AR-18; see
[architecture.md](architecture.md#video-macroblocks-yuv_mbs).

## Usage

```cpp
#include <TangNanoGPU.h>
#include <TinyH264Decoder.h>

TangNanoGPU gpu(transport);
SurfaceTangNano screen(gpu);
YUVFrameWriter video(gpu);
tinyh264::TinyH264Decoder<> decoder;

void onFrame(tinyh264::TinyH264Decoder<>& d, void*) {
  if (video.macroblocks() == 0) video.begin(d.width(), d.height());   // centred
  video.writeFrame(d.y(), d.strideY(), d.u(), d.v(), d.strideUV());
  screen.swap();     // show the finished frame, continue in the other buffer
  gpu.flush();       // stay at most one frame ahead
}

void setup() {
  gpu.begin();
  screen.begin();
  screen.setTarget(1);   // decode into the hidden buffer; swap() shows it
  decoder.setCallback(onFrame);
}
void loop() { decoder.write(data, size); }
```

`examples/video-player` is a complete sketch with an embedded clip. Any
other decoder works too: `writeFrame()` only needs the Y, Cb and Cr planes
and their strides.

### `YUVFrameWriter`

| Method | |
|---|---|
| `begin(w, h, x, y)` | picture size (multiples of 16, as decoded H.264 pictures are) and position. It is centred by default, and parts outside the screen are cropped |
| `writeFrame(Y, strideY, U, V, strideUV)` | sends the changed macroblocks to the current target buffer and returns how many were sent |
| `invalidate()` | the next frame into each buffer is sent completely. Call it after drawing over the video area |
| `setChangeDetection(false)` | always send every visible macroblock |

For lower-level control, `TangNanoGPU::writeYuvMacroblocks()` sends an
explicit list of macroblocks.

## Sending only changed macroblocks

Every macroblock (Y, Cb and Cr) is hashed with 32-bit FNV-1a. The hash is
compared with the one stored for the **target framebuffer**, and only
macroblocks whose hash changed are sent. Unchanged areas keep their pixels
in the FPGA's framebuffer.

- **Why not use the decoder's skip flags?** An H.264 P_Skip macroblock is
  not "unchanged": it is motion-compensated with a predicted vector, and
  the deblocking filter can modify it. Comparing content is always
  correct, and it works with any decoder.
- **Double buffering:** hashes are kept per buffer. A frame drawn into
  buffer 1 is compared with what buffer 1 holds, which is two frames back,
  not with the frame just shown from buffer 0.
- **Memory:** 2 × 4 bytes per macroblock, plus a 2-byte index list. That is
  3 KB for 320×240 (300 macroblocks).
- **Cost:** hashing reads each decoded pixel once, which is small compared
  with decoding it.

A 32-bit hash can in principle collide. The macroblock would then keep its
old content until it changes again. The probability per changed macroblock
is about 1 in 4 billion.

## Performance

**Link:** one macroblock is 388 bytes (4 position + 384 YUV): about 97 µs
over SPI at 32 MHz, or 39 µs over quad SPI at 40 MHz (bus time). Measured
macroblock counts with the test clip (`tools/golden/clips`, 30 frames of
colour bars with moving boxes):

| | Macroblocks sent | Bytes per frame | SPI 32 MHz | Quad SPI 40 MHz |
|---|---|---|---|---|
| first frame into each buffer | 300 of 300 | 116 KB | ≈ 29 ms | ≈ 6 ms |
| following frames (average) | ≈ 35 of 300 (12%) | ≈ 13.6 KB | ≈ 3.4 ms | ≈ 0.7 ms |

Real video with camera motion changes more of the picture. Even a full
frame every frame fits: about 34 fps over SPI and well over 100 fps over
quad SPI, as far as the link is concerned.

**FPGA:** a macroblock takes about 1,150 clock cycles (≈ 18 µs at 64.8 MHz),
estimated from the state machine: 2 cycles per input byte plus 16 row
writes. That is still about twice as fast as quad SPI delivers
macroblocks.

**Decoding** usually limits the frame rate. TinyH264 decodes QCIF
(176×144) in about 20 ms on an ESP32 and 16 ms on an ESP32-S3. Scaled by
pixel count, that gives roughly:

| Picture | ESP32 | ESP32-S3 |
|---|---|---|
| 256×192 | ~40 ms (~25 fps) | ~31 ms (~32 fps) |
| 320×240 | ~64 ms (~15 fps) | ~50 ms (~20 fps) |

These are extrapolations, not measurements. Decoding a 320×240 picture
also needs about 2 × 115 KB of frame memory in TinyH264, which needs PSRAM.
The example therefore uses 256×192.

## Verification

`make golden` runs the video test when TinyH264 is installed next to this
library (`TINYH264_DIR`). It checks three things:

1. **Converter:** the conversion formula is compared with TinyH264's
   `yuvToRgb8()` + RGB565 packing for all 16.7 million YUV inputs. There
   are 0 differences.
2. **All 30 frames, through the emulator:** `tools/golden/clips/test_320x240.264`
   is decoded with TinyH264, and every frame goes through `YUVFrameWriter`
   into alternating buffers, shifted to (−8, 4) so macroblocks are cropped
   at the screen edges. The protocol emulator's framebuffer must equal
   TinyH264's `toRGB565()` output for every frame (byte swap turned off
   with `setByteSwap(false)`; by default `toRGB565()` returns the same
   values byte-swapped for SPI panels).
3. **First 8 frames, through the RTL:** the recorded SPI stream is replayed
   into the RTL. The final framebuffer must match pixel for pixel.

## License note

TinyH264 is GPL-3.0. TangNanoGPU itself (Apache-2.0) does not depend on it.
`YUVFrameWriter` takes plain YUV planes, but a sketch that links TinyH264
falls under TinyH264's license.
