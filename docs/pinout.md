# Pinout and wiring

All signals are 3.3 V. Programming the FPGA uses the board's own USB-C port
(onboard BL616 USB-JTAG), not any of these pins.

| Tang Nano 20K pin | Signal | Direction | Connect to (ESP32 example) | Notes |
|---|---|---|---|---|
| 73 | `spi_sck` | MCU → FPGA | GPIO 18 (VSPI SCK) | weak pull-down |
| 74 | `spi_mosi` | MCU → FPGA | GPIO 23 (VSPI MOSI) | weak pull-down |
| 75 | `spi_miso` | FPGA → MCU | GPIO 19 (VSPI MISO) | tri-stated unless the board is addressed |
| 76 | `spi_cs_n` | MCU → FPGA | GPIO 5 | weak pull-up |
| 71 | `gpu_busy` | FPGA → MCU | GPIO 4 | high = command FIFO almost full; strongly recommended |
| GND | GND | | GND | |

These five header pins have no other function on the board. In the
[arduino-tangnano20k](https://github.com/pschatzmann/arduino-tangnano20k)
core they are GPIO0/1/2/11/18.

For RP2040 the examples use: SCK 18, MOSI 19, MISO 16, CS 17, BUSY 20.

## On-board resources used

| Pins | Function |
|---|---|
| 4 | 27 MHz oscillator |
| 33/34, 35/36, 37/38, 39/40 | HDMI TMDS clock, D0 (blue), D1 (green), D2 (red), as differential pairs. Same pins as Apicula's Tang Nano 20K constraints |
| 88 (S1) | reset |
| 87 (S2) | hold for colour bars |
| 15–20 | LEDs (active low): 0 heartbeat, 1 SDRAM ready, 2 error, 3 engine busy, 4 SPI active, 5 scanout late |
| embedded SDRAM | placed by port name (`O_sdram_*`, `IO_sdram_dq`), not in the `.cst` |

To change pins, edit `gateware/constraints/tangnano20k.cst` and rebuild.
Avoid 33–40 (HDMI), 15–20 (LEDs) and the pins used by on-board peripherals.
