# Pinout and wiring

All signals are 3.3 V. Programming the FPGA uses the board's own USB-C port
(onboard BL616 USB-JTAG), not any of these pins.

## Host link

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
which this design doesn't use. A `LINK=spi` bitstream (see
[building.md](building.md)) has no IO2/IO3 and leaves 25/26 free.

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
| 33/34, 35/36, 37/38, 39/40 | HDMI TMDS clock, D0 (blue), D1 (green), D2 (red), as differential pairs. Same pins as Apicula's Tang Nano 20K constraints |
| 88 (S1) | reset |
| 87 (S2) | hold for colour bars |
| 15–20 | LEDs (active low): 0 heartbeat, 1 SDRAM ready, 2 error, 3 engine busy, 4 SPI active, 5 scanout late |
| embedded SDRAM | placed by port name (`O_sdram_*`, `IO_sdram_dq`), not in the `.cst` |

To change pins, edit `gateware/constraints/tangnano20k.cst` (and
`qspi.cst` for IO2/IO3) and rebuild. Avoid 33–40 (HDMI), 15–20 (LEDs) and the
pins used by on-board peripherals.
