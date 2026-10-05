/**
 * @file ping.ino
 * @brief Checks the wiring to a Tang Nano 20K running the TangNanoGPU
 * bitstream: PING, STATUS, and a colour cycle on the HDMI output.
 *
 * Wiring (Tang Nano 20K pin -> MCU): 27 SCK, 28 MOSI, 29 MISO, 30 CS,
 * 31 BUSY, GND - GND; quad SPI adds 25 IO2 and 26 IO3. All 3.3V. See
 * docs/pinout.md.
 */
#include <SPI.h>
#include <TangNanoGPU.h>

// Interface: plain SPI (any MCU) or quad SPI (ESP32 family, IO2/IO3 wired
// to FPGA pins 25/26) - uncomment to select quad:
// #define TANGNANOGPU_LINK_QSPI

#if defined(TANGNANOGPU_LINK_QSPI) && defined(ESP32)
#if CONFIG_IDF_TARGET_ESP32
// VSPI IO_MUX pins: SCK 18, IO0/MOSI 23, IO1/MISO 19, IO2 22, IO3 21, CS 5, BUSY 4
TransportQSPI_ESP32 transport(18, 23, 19, 22, 21, 5, 4);
#else
// SCK 12, IO0 11, IO1 13, IO2 14, IO3 9, CS 10, BUSY 8
TransportQSPI_ESP32 transport(12, 11, 13, 14, 9, 10, 8);
#endif
#else
#if defined(ESP32)
const int kCsPin = 5, kBusyPin = 4;     // VSPI: SCK 18, MISO 19, MOSI 23
#elif defined(ARDUINO_ARCH_RP2040)
const int kCsPin = 17, kBusyPin = 20;   // SPI0: SCK 18, MOSI 19, MISO 16
#else
const int kCsPin = 10, kBusyPin = 9;
#endif
TransportSPI transport(SPI, kCsPin, kBusyPin);
#endif
TangNanoGPU gpu(transport);

void setup() {
  Serial.begin(115200);
  delay(1000);
  if (!gpu.begin()) {
    Serial.println("No answer from the Tang Nano 20K - check wiring and bitstream");
    while (true) delay(1000);
  }
  Serial.printf("TangNanoGPU gateware version %u, %s link, quad %s\n", gpu.version(),
                transport.isQuad() ? "quad-SPI" : "SPI",
                gpu.supportsQuad() ? "supported" : "not in this bitstream");
}

void loop() {
  static uint8_t hue = 0;
  // simple colour wheel on the whole screen
  uint8_t r = hue < 85 ? 255 - hue * 3 : hue < 170 ? 0 : (hue - 170) * 3;
  uint8_t g = hue < 85 ? hue * 3 : hue < 170 ? 255 - (hue - 85) * 3 : 0;
  uint8_t b = hue < 85 ? 0 : hue < 170 ? (hue - 85) * 3 : 255 - (hue - 170) * 3;
  gpu.fillRect(0, 0, kWidth, kHeight, RGB565(r, g, b).getValue());
  hue += 4;

  GPUStatus s = gpu.status();
  Serial.printf("frames=%u cmdFree=%u flags=0x%02x%s\n", s.frameCount, s.cmdFree, s.flags,
                s.error() ? " ERROR" : "");
  delay(500);
}
