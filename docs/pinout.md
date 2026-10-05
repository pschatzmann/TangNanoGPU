# Pinout and wiring

All signals are 3.3 V. Programming the FPGA uses the board's own USB-C port
(onboard BL616 USB-JTAG), not any of these pins.

There are two kinds of bitstream (see [building.md](building.md)):

- **HDMI** (default, `gateware/build/top_tangnano20k.fs`): picture on the
  HDMI connector, MCU link on pins 27–31.
- **RGB LCD** (`VIDEO=lcd`, `gateware/build/lcd/top_tangnano20k.fs`):
  picture on a 4.3" 480×272 panel on the 40-pin RGB connector. That
  connector shares FPGA pins with the HDMI output and with pins 25–31, so
  this build has no HDMI and moves the MCU link to pins 73–76/71.

## Host link (HDMI build)

The SPI pins (27–30) are the same as in the sibling
[TangNanoFaust](https://github.com/pschatzmann/TangNanoFaust) and
[TangNanoAI](https://github.com/pschatzmann/TangNanoAI) projects, so one MCU
wiring works with all three bitstreams.

| Tang Nano 20K pin | Signal | Direction | Notes |
|---|---|---|---|
| 27 | `spi_sck` | MCU → FPGA | weak pull-down |
| 28 | `spi_mosi` (IO0) | MCU → FPGA | weak pull-down |
| 29 | `spi_miso` (IO1) | FPGA → MCU, both ways in quad mode | tri-stated unless the board is addressed |
| 30 | `spi_cs_n` | MCU → FPGA | weak pull-up |
| 31 | `gpu_busy` | FPGA → MCU | high = command FIFO almost full; strongly recommended |
| 25 | `spi_io2` (quad only) | MCU → FPGA | weak pull-up; leave open for plain SPI |
| 26 | `spi_io3` (quad only) | MCU → FPGA | weak pull-up; leave open for plain SPI |
| GND | GND | | |

Pins 25–31 belong to the RGB LCD connector (LCD_HS, LCD_VS, LCD_B7…B3),
which the HDMI build doesn't use. A `LINK=spi` bitstream (see
[building.md](building.md)) has no IO2/IO3 and leaves 25/26 free.

## Host link (LCD build)

| Tang Nano 20K pin | Signal | Notes |
|---|---|---|
| 73 | `spi_sck` | weak pull-down |
| 74 | `spi_mosi` (IO0) | weak pull-down |
| 75 | `spi_miso` (IO1) | |
| 76 | `spi_cs_n` | weak pull-up |
| 71 | `gpu_busy` | |
| 72 | `spi_io2` (quad only) | weak pull-up |
| 86 | `spi_io3` (quad only) | weak pull-up |

These are header pins with no other on-board function. The MCU side is
wired exactly as for the HDMI build; only the FPGA pins differ.

## 40-pin RGB LCD connector (LCD build)

Plug a Sipeed 4.3" 480×272 RGB panel into the FPC connector. The
320×240 framebuffer is shown 1:1, centred, with a black border.

| Signal | FPGA pins |
|---|---|
| R[4:0] | 38, 39, 40, 41, 42 |
| G[5:0] | 32, 33, 34, 35, 36, 37 |
| B[4:0] | 27, 28, 29, 30, 31 |
| CLK / DE / HSYNC / VSYNC | 77 / 48 / 25 / 26 |
| backlight enable | 49 (driven high) |

Pin assignment and panel timing (9 MHz pixel clock; 480 + 8 + 4 + 39
horizontal, 272 + 8 + 4 + 8 vertical; about 58 Hz) follow Apicula's
`pll-nanolcd` example for this board and panel.

### MCU pins used by the examples

| | SCK | MOSI / IO0 | MISO / IO1 | CS | BUSY | IO2 | IO3 |
|---|---|---|---|---|---|---|---|
| ESP32, SPI (`TransportSPI`, VSPI) | 18 | 23 | 19 | 5 | 4 | – | – |
| ESP32, quad (`TransportQSPI_ESP32`, VSPI IO_MUX pins) | 18 | 23 | 19 | 5 | 4 | 22 | 21 |
| ESP32-S3 / others, quad | 12 | 11 | 13 | 10 | 8 | 14 | 9 |
| RP2040, SPI (SPI0) | 18 | 19 | 16 | 17 | 20 | – | – |

On the classic ESP32, SPI clocks above about 26 MHz need the SPI host's
IO_MUX pins (as in the table). Other MCU pins work at lower clocks.

## On-board resources used

| Pins | Function |
|---|---|
| 4 | 27 MHz oscillator |
| 33/34, 35/36, 37/38, 39/40 | HDMI build: HDMI TMDS clock, D0 (blue), D1 (green), D2 (red), as differential pairs. Same pins as Apicula's Tang Nano 20K constraints. LCD build: part of the RGB data bus |
| 88 (S1) | reset |
| 87 (S2) | hold for colour bars |
| 15–20 | LEDs (active low): 0 heartbeat, 1 SDRAM ready, 2 error, 3 engine busy, 4 SPI active, 5 scanout late |
| embedded SDRAM | placed by port name (`O_sdram_*`, `IO_sdram_dq`), not in the `.cst` |

To change pins, edit the files in `gateware/constraints/` and rebuild:
`base.cst` (clock, buttons, LEDs), `hdmi.cst` / `lcd.cst` (picture
output), `link_hdmi.cst` / `link_lcd.cst` (SPI and BUSY) and
`link_*_quad.cst` (IO2/IO3). Avoid 15–20 (LEDs), the pins of the picture
output you use and the pins used by on-board peripherals.
