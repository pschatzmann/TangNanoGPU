/**
 * @file link-benchmark.ino
 * @brief Measures the host link: full-frame pixel uploads (WRITE_RECT),
 * small commands per second, and readback speed. Run it once with plain
 * SPI and once with TANGNANOGPU_LINK_QSPI to compare the interfaces.
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

// one framebuffer row of pixels, reused for every row of a full frame
static uint8_t row[kWidth * 2];

void setup() {
  Serial.begin(115200);
  delay(1000);
  if (!gpu.begin()) {
    Serial.println("Tang Nano 20K not found (or quad link with a SPI-only bitstream)");
    while (true) delay(1000);
  }
  Serial.printf("link: %s\n", transport.isQuad() ? "quad SPI" : "SPI");
}

void loop() {
  // 1. full-frame pixel upload: 320 x 240 x 2 = 153.6 KB
  for (int i = 0; i < kWidth; ++i) {
    uint16_t c = RGB565(i, 255 - i, (i * 3) & 255).getValue();
    row[i * 2] = c & 0xff;
    row[i * 2 + 1] = c >> 8;
  }
  uint32_t t0 = micros();
  for (int y = 0; y < kHeight; ++y) gpu.writeRect(0, y, kWidth, 1, row);
  gpu.flush();
  uint32_t us = micros() - t0;
  Serial.printf("full frame: %.1f ms (%.2f MB/s)\n", us / 1000.0f, 153600.0f / us);

  // 2. small commands: 1000 filled rectangles
  t0 = micros();
  for (int i = 0; i < 1000; ++i)
    gpu.fillRect((i * 7) % 300, (i * 13) % 220, 20, 20, RGB565(i, i * 3, i * 7).getValue());
  gpu.flush();
  us = micros() - t0;
  Serial.printf("1000 fillRect: %.1f ms (%.0f commands/s)\n", us / 1000.0f, 1e9f / us);

  // 3. readback (single-line SPI at the read clock)
  t0 = micros();
  gpu.readRect(0, 0, kWidth, 1, row);
  us = micros() - t0;
  Serial.printf("read 1 row: %.2f ms\n\n", us / 1000.0f);
  delay(2000);
}
