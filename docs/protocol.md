# SPI protocol

The host MCU is the SPI master and the Tang Nano 20K is the slave. The bus
uses mode 0 (CPOL=0, CPHA=0), MSB first, either single-line SPI or quad SPI
(four data lines) for write transactions. It is implemented in
`gateware/rtl/spi_gpu.v` (link layer) and `gateware/rtl/gpu_exec.v`
(drawing commands). The host side lives in `src/TangNanoGPU/GPUDevice.h`
and the transports (`TransportSPI.h`, `TransportQSPI_ESP32.h`).

## Transactions

One transaction is one chip-select-low period:

```
CS low  [ADDR] [OPCODE] [payload ...]  CS high
```

- **ADDR**: bits 6:0 are the board address (a gateware parameter, default
  0); the board answers only if they match. Other boards on the same bus
  keep MISO tri-stated and ignore the transaction. Bit 7 is the **quad
  flag** (see below).
- **OPCODE**: one byte. Immediate opcodes (below) are answered by the SPI
  slave itself. Every other opcode, together with all payload bytes up to
  CS high, goes into the 4 KB command FIFO. The drawing engine runs those
  commands strictly in order, in the background.
- Each command must be sent in its own transaction, with exactly the
  payload length listed below. If the engine sees an unknown opcode it sets
  the sticky `bad_opcode` flag and the stream is out of sync. Recover with
  `RESET`.

### Single-line and quad SPI

The interface is selected per transaction, so one bitstream serves both:

- **Single-line SPI:** ADDR bit 7 = 0. Bytes go out on MOSI (IO0), MSB first.
  Works with every MCU (`TransportSPI`).
- **Quad SPI (writes only):** the ADDR byte is still sent single-line on
  IO0, with bit 7 set. Every following byte of that transaction goes out on
  IO3..IO0, four bits per SCK rising edge, high nibble first (IO3 = bit 7):
  two clocks per byte. MISO (IO1) is an input to the FPGA then.
  `TransportQSPI_ESP32` does this with ESP-IDF's `spi_master` (command phase
  single-line, data phase `SPI_TRANS_MODE_QIO`).
- Read transactions (PING, STATUS, READ_DATA) are always single-line.

A bitstream built with `LINK=spi` has no IO2/IO3 and ignores bit 7. PING
reports which kind is loaded.

### Clock rates

The FPGA receives with SCK as the clock (no oversampling) and moves every
byte into its 64.8 MHz system clock through a small asynchronous FIFO.

- **Writes:** tested in simulation up to about 42 MHz, single-line and
  quad. `TransportSPI` defaults to 32 MHz and `TransportQSPI_ESP32` to
  40 MHz; long jumper wires may need less.
- **Reads** (PING, STATUS, READ_DATA): the response byte is prepared in the
  system clock domain after the previous byte arrived, so reads need a slow
  SCK: 4 MHz (the default `readHz` of both transports), at most about 5 MHz.

### Response timing

As in TangNanoAI, the response to the byte sent in transfer N goes out
during transfer N+1. In practice, response bytes start in the transfer
right after the opcode, and no dummy byte is needed.

### Flow control: BUSY

`gpu_busy` (pin 31) is high while the command FIFO has less than 1024 bytes
free, and during reset. The host checks BUSY before every chunk (256 bytes
for `TransportSPI`, 512 for `TransportQSPI_ESP32`). CS may stay low while
it waits, because SCK can pause at any time. This lets one transaction
carry a payload of any size, such as a full-screen `WRITE_RECT`.

Without a BUSY wire, the library limits each command to half the FIFO and
polls `STATUS` for free space before sending.

## Data encoding

| Type | Encoding |
|---|---|
| `i16` / `u16` | 2 bytes, little endian |
| colour | RGB565, **high byte first**. This is the byte order of TinyGPU's `RGB565` values in memory (`RGB565::getValue()` stores the conventional value byte-swapped), so `Surface<RGB565>::data()` can be streamed out unchanged. |
| pixels | colours, row-major, no padding |

Coordinates are signed. Drawing is clipped against the current clip
rectangle, which the FPGA always keeps inside the 320×240 framebuffer. The
exceptions are PIXELS and WRITE_RECT with flag bit 1: like TinyGPU's
`setPixel()`, they are bounded only by the framebuffer.

## Immediate opcodes

| Op | Name | Payload | Response (starting with the byte after the opcode) |
|---|---|---|---|
| `01` | PING | – | `"TANG"`, the gateware version (`02`), then capabilities: bit 0 = quad SPI supported |
| `02` | RESET | – | – flushes both FIFOs; resets the drawing target and the shown buffer to 0, the clip rect to the full screen, and all sticky flags. Framebuffer contents are kept |
| `03` | STATUS | – | `cmd_free:u16`, `flags:u8`, `frame_count:u16`, `resp_used:u16` |
| `51` | READ_DATA | – | streams bytes from the response FIFO (`00` once it is empty) |

STATUS `flags`:

| Bit | Meaning |
|---|---|
| 0 | busy: engine executing, or commands queued |
| 1 | front buffer currently on screen |
| 2 | overflow (sticky): a command byte arrived while the FIFO was full |
| 3 | bad opcode (sticky): the stream is out of sync; send RESET |
| 4 | SDRAM initialised |
| 5 | current drawing target |
| 6 | scanout late (sticky): a line fetch was still running when the next line was requested |

## Queued commands

| Op | Name | Payload after the opcode | TinyGPU call |
|---|---|---|---|
| `10` | SET_TARGET | `buf:u8` | draw into framebuffer 0/1 |
| `11` | SHOW | `buf:u8` | show that buffer from the next frame on (switches in vertical blanking) |
| `12` | WAIT_VSYNC | – | following commands wait for the next frame start |
| `13` | SET_CLIP | `x:i16 y:i16 w:u16 h:u16` | `pushClipRect`/`popClipRect` (the stack is kept on the host) |
| `20` | FILL_RECT | `x y w h color` | `fillRect`, `clear` |
| `21` | LINE | `x0:i16 y0:i16 x1:i16 y1:i16 color` | `drawLine`, `drawRect` |
| `22` | PIXELS | `n:u16`, then n × (`x:i16 y:i16 color`) | `setPixel`, batched by the host. Like TinyGPU's `setPixel()`, only the screen bounds apply, **not** the clip rect |
| `23` | CIRCLE | `x:i16 y:i16 r:u16 color fill:u8` | `drawCircle` / `fillCircle` |
| `30` | WRITE_RECT | `x:i16 y:i16 w:u16 h:u16 flags:u8 key:color`, then w·h pixels | `drawSprite` (flags bit 0 = skip `key` pixels; bit 1 = ignore the clip rect, used for runs of `setPixel()` calls), `DisplayDriver::writeData` |
| `31` | UPLOAD | `row:u16 w:u16 h:u16`, then w·h pixels | stores an image at SDRAM row `row` (one row per image line, w ≤ 512) |
| `32` | COPY_RECT | `srow:u16 sx:u16 sy:u16 w:u16 h:u16 dx:i16 dy:i16 flags:u8 key:color` | copies from the surface at SDRAM row `srow` (an uploaded image, or a framebuffer) to (dx, dy) in the target: `blit`, `scroll` |
| `34` | YUV_MBS | `n:u16`, then n × (`x:i16 y:i16`, Cb[64], Cr[64], Y[256]) | video: 16×16 macroblocks of a YUV 4:2:0 picture at pixel position (x, y), converted to RGB565 by the FPGA (see below); clipped like WRITE_RECT. `YUVFrameWriter` sends only changed macroblocks |
| `40` | MASK | `x:i16 y:i16 w:u16 h:u16 flags:u8 fg:color bg:color`, then rows of bits | `drawText`. flags bit 0 = 2 bits per pixel. 1 bpp: 1 = fg. 2 bpp: `01` = fg, `10` = bg, otherwise unchanged. MSB first, each row padded to a whole byte. |
| `50` | READ_RECT | `x:u16 y:u16 w:u16 h:u16` | `getPixel`, `copySprite`. Pushes w·h pixels into the 2 KB response FIFO; collect them with READ_DATA. |

### YUV → RGB565 conversion (YUV_MBS)

The conversion is ITU-R BT.601 limited range. It uses the integer formula
from TinyH264's `yuvToRgb8()`, which is common in embedded decoders, so the
result is bit-identical to TinyH264's own `toRGB565()`. Note that
`toRGB565()` returns its values byte-swapped by default (for SPI panels);
with `setByteSwap(false)` they are the native values below:

```
c = Y − 16,  d = Cb − 128,  e = Cr − 128
R = clip((298c + 409e + 128) >> 8)
G = clip((298c − 100d − 208e + 128) >> 8)
B = clip((298c + 516d + 128) >> 8)
RGB565 = {R[7:3], G[7:2], B[7:3]}
```

Chroma sample (i/2, j/2) applies to luma pixel (i, j) of the macroblock.

### SDRAM layout

The 8 MB SDRAM has 8192 rows of 512 pixels (256 × 32-bit words). Each
framebuffer line is one SDRAM row:

| Rows | Use |
|---|---|
| 0–239 | framebuffer 0 |
| 256–495 | framebuffer 1 |
| 512–8191 | image store for `UPLOAD`/`COPY_RECT`, allocated by the host (`kImageRowBase`) |

## Exactness

LINE, CIRCLE, FILL_RECT and the clipping rules use the same integer
algorithms as TinyGPU's `SurfaceBase.h`:

- Bresenham line;
- midpoint circle, with spans for filled circles;
- the inclusive clip rules of `setPixelClipped`/`drawHorizontalLineClipped`.

The FPGA therefore draws pixel-identical results. `tools/golden` checks
this with three test scenes that together cover every command: a TinyGPU
scene, a TinyMaterialDesign screen with readbacks, and decoded H.264 video
(see [architecture.md](architecture.md#verification-status)).

One difference: TinyGPU's software surface takes `size_t` coordinates, so
negative values wrap around. For example, a `fillRect` that starts left of
x = 0 draws nothing there. The FPGA treats coordinates as signed 16-bit
and draws the visible part.
