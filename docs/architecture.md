# Architecture

The library turns a Tang Nano 20K into a TinyGPU "graphics card".

- **The microcontroller** runs TinyGPU and sends short drawing commands over
  SPI or quad SPI.
- **The FPGA** keeps the framebuffer in its 8 MB SDRAM and draws the
  commands in hardware. It also streams the picture to HDMI continuously,
  with no help from the MCU.

```
 MCU (TinyGPU calls)
   │ SPI / quad SPI (~40 MHz)   ▲ BUSY / MISO (4 MHz reads)
   ▼                            │
 spi_gpu ──► cmd FIFO (4 KB) ──► gpu_exec ──────────────┐ port B (read/write)
   ▲                                │ span buffer, read  │
   └──── resp FIFO (2 KB) ◄─────────┘ buffer, YUV→RGB    ▼
                                                 sdram_ctrl ──► 8 MB SDRAM
 HDMI ◄── dvi_tx ◄── scanout (320×240 → 640×480) ◄──────┘ port A (read, priority)
          TMDS + OSER10     line buffer (dual clock)
```

## Clocks

| Clock | Frequency | Source | Used by |
|---|---|---|---|
| `spi_sck` | host's SPI clock (≤ ~40 MHz) | MCU | SPI/quad receive shift register and the write side of the receive FIFO |
| `clk` | 64.8 MHz | rPLL #1 (27 × 12 / 5) | SPI byte parser, FIFOs, drawing engine, SDRAM controller, scanout fetch |
| `clk_sdram` | 64.8 MHz, shifted 180° | rPLL #1 CLKOUTP | SDRAM chip clock |
| `clk_pix_x5` | 126 MHz | rPLL #2 (27 × 14 / 3) | OSER10 serialisers (DDR, giving 252 Mbit/s per TMDS lane) |
| `clk_pix` | 25.2 MHz | CLKDIV ÷5 | video timing, TMDS encoders, line-buffer read |

The PLL settings come from Apicula's `gowin_pll` calculator and its DVI
example. They are not hand-derived. Packing two PLLs needs Apicula 0.34 or
newer (see [building.md](building.md)).

## Host link (`spi_gpu.v`, `async_fifo.v`)

SCK itself clocks the receive shift register; there is no oversampling.
Each completed byte goes, tagged with a "first byte of the transaction"
flag, into a 16-entry asynchronous FIFO (Gray-coded pointers, 2-flop
synchronisers) and is parsed in the 64.8 MHz domain. The flag frames
transactions, so a CS that rises right after the last byte cannot overtake
it. This raises the write clock from about 16 MHz (oversampling) to about
40 MHz.

- **Quad SPI:** when the address byte's bit 7 is set, the rest of the
  transaction arrives on IO3..IO0, four bits per clock. One bitstream
  serves both interfaces, chosen per transaction by the host.
- **Reads:** the response byte is chosen in the system domain after the
  previous byte arrived, and loaded into the SCK-domain MISO register at
  the next byte boundary. That needs a slow read clock (4 MHz).
- **Power-up:** the SCK-domain registers and the FIFO's write pointer have
  explicit initial values. They are otherwise only reset by a rising CS
  edge, and at power-up CS is already high.
- **Build option:** `LINK=spi` leaves out IO2/IO3 and the quad receiver.

## SDRAM: row bursts

TangNanoAI's byte-wide controller costs about 5 clocks per byte, which is
far too slow for video. `sdram_ctrl.v` keeps the same proven init sequence
and read-sample timing (a READ registered at edge E is sampled at
E + CAS + 1). Its requests, however, are **bursts of 1–256 32-bit words
inside one SDRAM row**:

- one ACTIVATE, then one READ or WRITE per clock to consecutive columns;
- burst length 1 in the mode register, so the burst can stop at any word;
- auto-precharge on the last access.

Every framebuffer line is exactly one SDRAM row: 512 pixels of space, of
which 320 are used. Therefore:

- the line address is `{buffer, y, x/2}`, with no multiplier;
- a whole framebuffer line moves in about 170 clocks;
- every write word carries byte enables (DQM), so single pixels and partial
  words need no read-modify-write.

There are two ports:

- **Port A** (scanout, read-only) always wins arbitration.
- **Port B** serves the drawing engine.

Arbitration happens only between bursts. The longest burst is about 4.2 µs
and refresh runs every 7 µs, so both the scanout deadlines and the refresh
budget (15.6 µs) hold.

## Scanout (`scanout.v`)

- **Prefetch:** source line *t* is fetched into one half of a 2×160-word
  line buffer while line *t−1* is displayed from the other half. Each
  source line is shown on two video lines, so a fetch has about 63 µs.
- **Line 0:** it is fetched during the last blanking line.
- **Bandwidth:** 160 words × 240 lines × 60 Hz ≈ 2.3 M words/s, about 4% of
  the SDRAM's bandwidth in burst mode.
- **Clock crossing:** the line buffer is a dual-clock `SDPB`, written at
  64.8 MHz and read at 25.2 MHz. Requests cross from the pixel domain as a
  toggle plus a line number that stays stable for a whole video line.
- **Buffer switch:** `SHOW` only changes the front buffer when line 0 is
  requested, so double buffering never tears.
- **Colour bars:** holding button S2 shows colour bars instead of the
  framebuffer, which tests HDMI without the MCU or the SDRAM.

## Drawing engine (`gpu_exec.v`)

Each command is broken down into two primitives on one framebuffer line:

- **Span write:** one write burst over the words that cover `x0..x1`. The
  data is either a constant colour or the *span buffer*, where pixels are
  staged at their destination x, each with a valid flag. The x range and
  the valid flags give the byte enables.
  - Colour-keyed sprites and text masks become "invalid" pixels.
  - Odd start and end pixels just mask half a word.
- **Span read:** a read burst into the *read buffer*, indexed by SDRAM
  column. COPY_RECT and READ_RECT use it.

How each command uses these primitives:

| Command | How |
|---|---|
| FILL_RECT | clip once, then one constant span write per row |
| LINE, CIRCLE outline, PIXELS | one single-pixel span write per visible pixel; off-screen pixels cost 1–2 clocks and no SDRAM access |
| CIRCLE fill | up to 4 clipped constant spans per midpoint step |
| WRITE_RECT, UPLOAD, MASK | stage one row from the FIFO into the span buffer, then one span write |
| COPY_RECT | span read of the source row, stage it (3-stage pipeline, 1 pixel per clock, colour key), span write. Rows are copied bottom-up when the destination lies below the source, so overlapping scrolls are correct |
| READ_RECT | span read, then 2 bytes per pixel into the response FIFO |
| YUV_MBS | per macroblock: chroma into a LUT-RAM buffer, then each luma row through the YUV→RGB converter into the span buffer and one span write (see below) |

### Measured performance

Engine time per command, from `tb_top.v` at 64.8 MHz, including the time
the command takes to arrive over a 16 MHz SPI link:

| Operation | Time |
|---|---|
| clear 320×240 | 0.72 ms |
| line, 320-pixel diagonal | 87 µs |
| circle r = 100 (outline / filled) | 146 µs / 385 µs |
| scroll the whole screen | 2.6 ms |
| 24×24 colour-keyed blit from SDRAM | 39 µs |

The host link is the slow part for pixel data. A full-screen `WRITE_RECT`
(153.6 KB) takes about 38 ms over SPI at 32 MHz and about 8 ms over quad
SPI at 40 MHz (bus time, without the MCU's per-transaction overhead).
Sprites and images that are reused should still be uploaded once and drawn
with `blit()`.

## Video macroblocks (`YUV_MBS`)

Each 16×16 macroblock arrives with its chroma first: Cb and Cr, 128 bytes,
go into a small LUT-RAM buffer. The 256 luma bytes then stream through a
two-stage converter:

1. the constant products (298, 409, 100, 208, 516), written as shift-and-add,
   so no multipliers are needed;
2. the sums, clipping and RGB565 packing.

The pixels land in the span buffer, and each macroblock row becomes one
8-word span write, clipped like WRITE_RECT. The formula is TinyH264's
(see [protocol.md](protocol.md)), so the output matches its `toRGB565()`
bit for bit (with `toRGB565()`'s default byte swap turned off). Details and
figures: [video.md](video.md).

Why there is no H.264 decoder in hardware: a decoder needs entropy
decoding, inverse transforms, intra prediction, quarter-pixel motion
compensation and deblocking. Even small open-source baseline decoders are
several times larger than the roughly 12,000 LUTs left here, and yosys 0.33
does not infer the Gowin DSP blocks. Decoding on the MCU and sending only
changed YUV macroblocks gives most of the benefit for a few hundred LUTs.

## Exactness against TinyGPU

The rasterisers reproduce TinyGPU's own integer algorithms:

- Bresenham (`drawLine`);
- midpoint circle and filled-circle spans;
- the inclusive clip semantics.

Text, arcs and round rectangles are produced on the host by TinyGPU's own
code (fonts and `ISurface` defaults) and reach the FPGA as MASK, FILL_RECT,
LINE or PIXELS commands.

`tools/golden/run_golden.sh` (`make golden`) checks this end to end with
three scenes. Each is rendered by the software reference and by the host
library, whose recorded SPI stream is replayed into the full RTL with an
SDRAM model. All 76,800 pixels must match:

| Scene | Reference | Covers |
|---|---|---|
| TinyGPU test scene | TinyGPU's software `Surface<RGB565>` | every drawing primitive, text, clipping, sprites, uploads/blits, scrolling, `setPixel` runs, a `WireFrame3D` cube |
| TinyMaterialDesign screen with an open dialog (needs TinyMaterialDesign) | the same screen drawn into a software surface | widgets, and the dialog scrim with 240 readbacks; the RTL's READ_DATA bytes must equal the protocol emulator's |
| H.264 video (needs TinyH264) | TinyH264's `toRGB565()` | `YUV_MBS` and `YUVFrameWriter`: 30 frames through the emulator, the first 8 through the RTL, double-buffered and cropped at the screen edges; the converter is also checked against TinyH264 for all 16.7 M YUV inputs |

## Resources (GW2AR-18C, yosys 0.33 + nextpnr-himbaechel 0.11)

| Resource | Used | Available |
|---|---|---|
| LUT4 | 8,458 (40%) | 20,736 |
| DFF | 2,012 (12%) | 15,552 |
| BSRAM | 7 (15%) | 46 |
| RAM16SDP4 (LUT RAM) | 51 (7%) | 648 |
| rPLL | 2 (100%) | 2 |

| Clock | Required | Fmax after routing |
|---|---|---|
| `clk` | 64.8 MHz | 83.6 MHz |
| `clk_pix` | 25.2 MHz | 82.7 MHz |
| `spi_sck` | ~40 MHz | 354 MHz (register to register) |

The `spi_sck` figure covers only paths inside the FPGA. At 40 MHz the real
limit is the board-level timing: MOSI/IO setup against SCK through jumper
wires, and SCK reaching the receive registers over general routing rather
than a global clock net. That's why the library defaults are 32 MHz (SPI)
and 40 MHz (quad), and why they are easy to lower.

The 7 BSRAM blocks are: line buffer 1, command FIFO 2, response FIFO 1,
span buffer 2, read buffer 1.

### Toolchain notes

- **Block RAM cell names:** yosys 0.33 maps inferred simple dual-port
  memories to the old `SDPX9`/`DPX9` cells, and nextpnr 0.11 cannot place
  those. `rtl/bram_sdp.v` therefore instantiates Gowin's `SDPB` directly
  (as Apicula's examples do), and uses a behavioural model in simulation.
- **BSRAM output enable:** yosys 0.33 also ties the BSRAM output enable
  (OCE) low. `tools/fix_bram_oce.py` patches the netlist, as the
  arduino-tangnano20k core does. The direct `SDPB` instances already tie
  OCE high.
- **Second PLL:** Apicula 0.33's `gowin_pack` crashes on the second (left)
  PLL. Use 0.34 or newer.

## Verification status

**Verified in simulation (Icarus Verilog):**

- TMDS encoding: every symbol decodes back, and the DC balance holds.
- Video timing: exact 640×480@60 counts.
- SDRAM controller: against a protocol-checking SDRAM model, covering full
  row bursts, byte masks, port contention and refresh.
- Full chip over its pins: PING, STATUS, READ_RECT readback, RESET and
  bad-opcode recovery, over SPI at 10.8 MHz and ~42 MHz and over quad SPI
  at ~42 MHz, with 4 MHz reads.
- The three golden-model scenes above (TinyGPU, TinyMaterialDesign, H.264
  video), replayed over quad SPI at ~42 MHz, each pixel-identical to its
  reference.

**Verified with the real toolchain:** the design synthesises, places,
routes, meets timing and packs into a bitstream.

**Not yet verified on hardware:** no board was attached while this was
written. Bring-up order:

1. Hold S2 and look for colour bars. This checks HDMI, the PLLs and the
   OSER10/TLVDS output.
2. Run `examples/ping`. This checks the SPI wiring and SDRAM init, and
   reports whether the bitstream supports quad SPI. Then try it with
   `TANGNANOGPU_LINK_QSPI` and `examples/link-benchmark`.
3. Run `examples/basic-example`.
4. Optionally run `examples/material-design` and `examples/video-player`.

If the SDRAM reads back wrong data, check the `clk_sdram` phase first
(`PSDA_SEL` in `rtl/clocks.v`).
