# SPI protocol

The host MCU is the SPI master and the Tang Nano 20K is the slave. The bus
uses mode 0 (CPOL=0, CPHA=0), MSB first. It is implemented in
`gateware/rtl/spi_gpu.v` (link layer) and `gateware/rtl/gpu_exec.v`
(drawing commands). The host side lives in `src/TangNanoGPU/GPUDevice.h`.

## Transactions

One transaction is one chip-select-low period:

```
CS low  [ADDR] [OPCODE] [payload ...]  CS high
```

- **ADDR**: the board answers only if this byte equals its address. The
  address is a gateware parameter and defaults to `0x00`. Other boards on the
  same bus keep MISO tri-stated and ignore the transaction.
- **OPCODE**: one byte. Immediate opcodes (below) are answered by the SPI
  slave itself. Every other opcode, together with all payload bytes up to
  CS high, goes into the 4 KB command FIFO. The drawing engine runs those
  commands strictly in order, in the background.
- Each command must be sent in its own transaction, with exactly the
  payload length listed below. If the engine sees an unknown opcode it sets
  the sticky `bad_opcode` flag and the stream is out of sync. Recover with
  `RESET`.

### Clock rates

SCK, MOSI and CS are oversampled by the 64.8 MHz system clock.

- **Writes:** up to about 16 MHz. The library default is 10 MHz.
- **Reads** (PING, STATUS, READ_DATA): MISO changes a few system clocks
  after SCK falls, so use 4 MHz or less. `TransportSPI` uses separate write
  and read clocks for this.

### Response timing

As in TangNanoAI, the response to the byte sent in transfer N goes out
during transfer N+1. In practice, response bytes start in the transfer
right after the opcode, and no dummy byte is needed.

### Flow control: BUSY

`gpu_busy` (pin 71) is high while the command FIFO has less than 1024 bytes
free, and during reset. The host checks BUSY before every chunk of 256
bytes. CS may stay low while it waits, because SCK can pause at any time.
This lets one transaction carry a payload of any size, such as a
full-screen `WRITE_RECT`.

Without a BUSY wire, the library limits each command to half the FIFO and
polls `STATUS` for free space before sending.

## Data encoding

| Type | Encoding |
|---|---|
| `i16` / `u16` | 2 bytes, little endian |
| colour | RGB565, **high byte first**. This is the byte order of TinyGPU's `RGB565` values in memory (`RGB565::getValue()` stores the conventional value byte-swapped), so `Surface<RGB565>::data()` can be streamed out unchanged. |
| pixels | colours, row-major, no padding |

Coordinates are signed. Everything is clipped against the current clip
rectangle, which the FPGA always keeps inside the 320×240 framebuffer.

## Immediate opcodes

| Op | Name | Payload | Response (starting with the byte after the opcode) |
|---|---|---|---|
| `01` | PING | – | `"TANG"`, then the gateware version (`01`) |
| `02` | RESET | – | – flushes both FIFOs, resets target, clip and sticky flags; the picture stays |
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
| `40` | MASK | `x:i16 y:i16 w:u16 h:u16 flags:u8 fg:color bg:color`, then rows of bits | `drawText`. flags bit 0 = 2 bits per pixel. 1 bpp: 1 = fg. 2 bpp: `01` = fg, `10` = bg, otherwise unchanged. MSB first, each row padded to a whole byte. |
| `50` | READ_RECT | `x:u16 y:u16 w:u16 h:u16` | `getPixel`, `copySprite`. Pushes w·h pixels into the 2 KB response FIFO; collect them with READ_DATA. |

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
this for a test scene that covers every command.

One difference: TinyGPU's software surface takes `size_t` coordinates, so
negative values wrap around. For example, a `fillRect` that starts left of
x = 0 draws nothing there. The FPGA treats coordinates as signed 16-bit
and draws the visible part.
